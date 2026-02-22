defmodule FLAME.JobManager do
  @moduledoc """
  Advanced job queue and workflow management for Apple Containers FLAME backend.

  Provides enterprise-grade job orchestration including:
  - Priority-based job queuing with SLA tracking
  - Complex workflow orchestration with DAG execution
  - Job dependencies and conditional execution
  - Retry policies with exponential backoff and circuit breaking
  - Dead letter queues and job failure analysis
  - Cron-like scheduling for recurring jobs
  - Resource-aware job placement and scaling
  """

  use GenServer
  require Logger

  alias FLAME.{AlertManager, ClusterManager, SecurityManager}

  defstruct [
    :job_queues,
    :active_jobs,
    :workflows,
    :job_history,
    :schedulers,
    :retry_policies,
    :dead_letter_queue,
    :job_templates
  ]

  @max_retries 3
  # 5 minutes
  @default_timeout 300_000
  # 1 second
  @queue_process_interval 1_000
  # 1 hour
  @cleanup_interval 3_600_000
  # 30 seconds
  @metrics_interval 30_000

  ## Job States
  @state_pending :pending
  @state_queued :queued
  @state_running :running
  @state_completed :completed
  @state_failed :failed
  @state_cancelled :cancelled
  @state_timeout :timeout
  @state_retrying :retrying

  ## Job Priorities
  @priority_critical 1
  @priority_high 2
  @priority_normal 3
  @priority_low 4
  @priority_batch 5

  ## Public API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Submit a job for execution.
  """
  def submit_job(job_spec, options \\ %{}, server \\ __MODULE__) do
    GenServer.call(server, {:submit_job, job_spec, options})
  end

  @doc """
  Submit a workflow for execution.
  """
  def submit_workflow(workflow_spec, options \\ %{}, server \\ __MODULE__) do
    GenServer.call(server, {:submit_workflow, workflow_spec, options})
  end

  @doc """
  Get job status and details.
  """
  def get_job_status(job_id, server \\ __MODULE__) do
    GenServer.call(server, {:get_job_status, job_id})
  end

  @doc """
  Cancel a pending or running job.
  """
  def cancel_job(job_id, reason \\ "user_cancelled", server \\ __MODULE__) do
    GenServer.call(server, {:cancel_job, job_id, reason})
  end

  @doc """
  List jobs with optional filtering.
  """
  def list_jobs(filters \\ %{}, server \\ __MODULE__) do
    GenServer.call(server, {:list_jobs, filters})
  end

  @doc """
  Get workflow status and execution details.
  """
  def get_workflow_status(workflow_id, server \\ __MODULE__) do
    GenServer.call(server, {:get_workflow_status, workflow_id})
  end

  @doc """
  Schedule a recurring job using cron syntax.
  """
  def schedule_job(cron_expression, job_spec, options \\ %{}, server \\ __MODULE__) do
    GenServer.call(server, {:schedule_job, cron_expression, job_spec, options})
  end

  @doc """
  Unschedule a recurring job.
  """
  def unschedule_job(schedule_id, server \\ __MODULE__) do
    GenServer.call(server, {:unschedule_job, schedule_id})
  end

  @doc """
  Get job execution metrics and statistics.
  """
  def get_job_metrics(server \\ __MODULE__) do
    GenServer.call(server, :get_job_metrics)
  end

  @doc """
  Create a job template for reuse.
  """
  def create_job_template(template_spec, server \\ __MODULE__) do
    GenServer.call(server, {:create_job_template, template_spec})
  end

  @doc """
  Execute a job from a template.
  """
  def execute_template(template_id, parameters \\ %{}, server \\ __MODULE__) do
    GenServer.call(server, {:execute_template, template_id, parameters})
  end

  ## GenServer Callbacks

  def init(opts) do
    clean_opts = if is_list(opts), do: Keyword.delete(opts, :name), else: opts

    state = %__MODULE__{
      job_queues: initialize_job_queues(),
      active_jobs: %{},
      workflows: %{},
      job_history: [],
      schedulers: %{},
      retry_policies: initialize_retry_policies(clean_opts),
      dead_letter_queue: :queue.new(),
      job_templates: %{}
    }

    # Start periodic tasks
    schedule_queue_processing()
    schedule_cleanup()
    schedule_metrics_collection()

    # Initialize scheduled jobs from configuration
    state = load_scheduled_jobs(state, clean_opts)

    Logger.info("JobManager initialized with #{map_size(state.job_queues)} job queues")

    {:ok, state}
  end

  def handle_call({:submit_job, job_spec, options}, _from, state) do
    case validate_job_spec(job_spec) do
      :ok ->
        job = create_job_from_spec(job_spec, options)
        state = enqueue_job(job, state)

        Logger.info("Job submitted: #{job.id} (#{job.name})")

        # Send telemetry
        :telemetry.execute([:flame, :job, :submitted], %{}, %{
          job_id: job.id,
          priority: job.priority,
          queue: job.queue
        })

        {:reply, {:ok, job.id}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:submit_workflow, workflow_spec, options}, _from, state) do
    case validate_workflow_spec(workflow_spec) do
      :ok ->
        workflow = create_workflow_from_spec(workflow_spec, options)
        state = put_in(state.workflows[workflow.id], workflow)

        # Start workflow execution
        state = start_workflow_execution(workflow, state)

        Logger.info("Workflow submitted: #{workflow.id} (#{workflow.name})")

        {:reply, {:ok, workflow.id}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_job_status, job_id}, _from, state) do
    case find_job(job_id, state) do
      nil ->
        {:reply, {:error, :job_not_found}, state}

      job ->
        status = %{
          id: job.id,
          name: job.name,
          state: job.state,
          progress: job.progress,
          created_at: job.created_at,
          started_at: job.started_at,
          completed_at: job.completed_at,
          duration_ms: calculate_job_duration(job),
          retry_count: job.retry_count,
          error_message: job.error_message,
          result: job.result,
          queue: job.queue,
          priority: job.priority,
          resource_usage: job.resource_usage
        }

        {:reply, {:ok, status}, state}
    end
  end

  def handle_call({:cancel_job, job_id, reason}, _from, state) do
    case find_job(job_id, state) do
      nil ->
        {:reply, {:error, :job_not_found}, state}

      job when job.state in [@state_completed, @state_failed, @state_cancelled] ->
        {:reply, {:error, {:invalid_state, job.state}}, state}

      job ->
        cancelled_job = %{
          job
          | state: @state_cancelled,
            completed_at: System.system_time(:millisecond),
            error_message: "Cancelled: #{reason}"
        }

        state = update_job(cancelled_job, state)

        # Cancel the actual execution if running
        if job.state == @state_running and job.execution_pid do
          Process.exit(job.execution_pid, :cancelled)
        end

        Logger.info("Job cancelled: #{job_id} - #{reason}")

        {:reply, :ok, state}
    end
  end

  def handle_call({:list_jobs, filters}, _from, state) do
    all_jobs = get_all_jobs(state)
    filtered_jobs = apply_job_filters(all_jobs, filters)

    job_summaries =
      Enum.map(filtered_jobs, fn job ->
        %{
          id: job.id,
          name: job.name,
          state: job.state,
          priority: job.priority,
          queue: job.queue,
          created_at: job.created_at,
          duration_ms: calculate_job_duration(job)
        }
      end)

    {:reply, job_summaries, state}
  end

  def handle_call({:get_workflow_status, workflow_id}, _from, state) do
    case Map.get(state.workflows, workflow_id) do
      nil ->
        {:reply, {:error, :workflow_not_found}, state}

      workflow ->
        status = %{
          id: workflow.id,
          name: workflow.name,
          state: workflow.state,
          created_at: workflow.created_at,
          started_at: workflow.started_at,
          completed_at: workflow.completed_at,
          steps: Enum.map(workflow.steps, &format_workflow_step/1),
          current_step: workflow.current_step,
          progress_percentage: calculate_workflow_progress(workflow)
        }

        {:reply, {:ok, status}, state}
    end
  end

  def handle_call({:schedule_job, cron_expression, job_spec, options}, _from, state) do
    case validate_cron_expression(cron_expression) do
      :ok ->
        schedule_id = generate_schedule_id()

        scheduler = %{
          id: schedule_id,
          cron_expression: cron_expression,
          job_spec: job_spec,
          options: options,
          created_at: System.system_time(:millisecond),
          enabled: true,
          last_execution: nil,
          next_execution: calculate_next_execution(cron_expression)
        }

        state = put_in(state.schedulers[schedule_id], scheduler)

        Logger.info("Job scheduled: #{schedule_id} with cron #{cron_expression}")

        {:reply, {:ok, schedule_id}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unschedule_job, schedule_id}, _from, state) do
    case Map.get(state.schedulers, schedule_id) do
      nil ->
        {:reply, {:error, :schedule_not_found}, state}

      _scheduler ->
        state = %{state | schedulers: Map.delete(state.schedulers, schedule_id)}
        Logger.info("Job unscheduled: #{schedule_id}")
        {:reply, :ok, state}
    end
  end

  def handle_call(:get_job_metrics, _from, state) do
    metrics = calculate_job_metrics(state)
    {:reply, metrics, state}
  end

  def handle_call({:create_job_template, template_spec}, _from, state) do
    case validate_job_template(template_spec) do
      :ok ->
        template_id = generate_template_id()

        template = %{
          id: template_id,
          name: template_spec.name,
          description: template_spec.description,
          function: template_spec.function,
          parameters: template_spec.parameters || [],
          defaults: template_spec.defaults || %{},
          requirements: template_spec.requirements || %{},
          created_at: System.system_time(:millisecond),
          created_by: template_spec.created_by
        }

        state = put_in(state.job_templates[template_id], template)

        Logger.info("Job template created: #{template_id} (#{template.name})")

        {:reply, {:ok, template_id}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:execute_template, template_id, parameters}, _from, state) do
    case Map.get(state.job_templates, template_id) do
      nil ->
        {:reply, {:error, :template_not_found}, state}

      template ->
        # Merge parameters with template defaults
        job_parameters = Map.merge(template.defaults, parameters)

        job_spec = %{
          name: "#{template.name}-#{System.system_time(:millisecond)}",
          function: template.function,
          parameters: job_parameters,
          requirements: template.requirements
        }

        case validate_job_spec(job_spec) do
          :ok ->
            job = create_job_from_spec(job_spec, %{template_id: template_id})
            state = enqueue_job(job, state)

            Logger.info("Template job submitted: #{job.id} from template #{template_id}")

            {:reply, {:ok, job.id}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_info(:process_queues, state) do
    state = process_all_queues(state)
    schedule_queue_processing()
    {:noreply, state}
  end

  def handle_info(:cleanup_jobs, state) do
    state = cleanup_completed_jobs(state)
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(:collect_metrics, state) do
    collect_and_report_metrics(state)
    schedule_metrics_collection()
    {:noreply, state}
  end

  def handle_info(:check_scheduled_jobs, state) do
    state = check_and_execute_scheduled_jobs(state)
    schedule_job_checking()
    {:noreply, state}
  end

  def handle_info({:job_completed, job_id, result}, state) do
    case Map.get(state.active_jobs, job_id) do
      nil ->
        {:noreply, state}

      job ->
        completed_job = %{
          job
          | state: @state_completed,
            completed_at: System.system_time(:millisecond),
            result: result,
            progress: 100
        }

        state = update_job(completed_job, state)
        state = move_job_to_history(completed_job, state)

        Logger.info("Job completed: #{job_id}")

        # Send telemetry
        :telemetry.execute(
          [:flame, :job, :completed],
          %{
            duration_ms: calculate_job_duration(completed_job)
          },
          %{
            job_id: job_id,
            success: true
          }
        )

        # Check if this completes any workflow steps
        state = check_workflow_completion(job, state)

        {:noreply, state}
    end
  end

  def handle_info({:job_failed, job_id, error_reason}, state) do
    case Map.get(state.active_jobs, job_id) do
      nil ->
        {:noreply, state}

      job ->
        should_retry = should_retry_job(job, state.retry_policies)

        if should_retry do
          state = schedule_job_for_retry(job, job_id, error_reason, state)
          {:noreply, state}
        else
          state = handle_permanent_job_failure(job, job_id, error_reason, state)
          {:noreply, state}
        end
    end
  end

  def handle_info({:job_progress, job_id, progress_data}, state) do
    case Map.get(state.active_jobs, job_id) do
      nil ->
        {:noreply, state}

      job ->
        updated_job = %{
          job
          | progress: progress_data.percentage,
            resource_usage: progress_data.resource_usage,
            updated_at: System.system_time(:millisecond)
        }

        state = update_job(updated_job, state)
        {:noreply, state}
    end
  end

  def handle_info({:retry_job, job_id}, state) do
    case Map.get(state.active_jobs, job_id) do
      nil ->
        {:noreply, state}

      job when job.state == @state_retrying ->
        # Re-queue the job for execution
        retry_job = %{job | state: @state_queued}
        state = update_job(retry_job, state)
        state = enqueue_job_for_execution(retry_job, state)

        Logger.info("Retrying job: #{job_id} (attempt #{job.retry_count})")

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:job_timeout, job_id}, state) do
    case Map.get(state.active_jobs, job_id) do
      nil ->
        # Job already completed or not found
        {:noreply, state}

      job when job.state == @state_running ->
        Logger.warning("Job #{job_id} timed out after #{job.timeout_ms}ms")

        # Terminate the execution process if it's still running
        if job.execution_pid and Process.alive?(job.execution_pid) do
          Process.exit(job.execution_pid, :timeout)
        end

        # Update job state to timeout
        timeout_job = %{
          job
          | state: @state_timeout,
            completed_at: System.system_time(:millisecond),
            error_reason: "Job execution timed out"
        }

        state = update_job(timeout_job, state)
        {:noreply, state}

      _ ->
        # Job is not in running state
        {:noreply, state}
    end
  end

  ## Private Functions

  defp schedule_job_for_retry(job, job_id, error_reason, state) do
    retry_job = %{
      job
      | state: @state_retrying,
        retry_count: job.retry_count + 1,
        error_message: error_reason,
        next_retry_at: calculate_next_retry(job, state.retry_policies)
    }

    state = update_job(retry_job, state)
    schedule_job_retry(retry_job)

    Logger.warning("Job failed, scheduling retry: #{job_id} (attempt #{retry_job.retry_count})")

    state
  end

  defp handle_permanent_job_failure(job, job_id, error_reason, state) do
    failed_job = %{
      job
      | state: @state_failed,
        completed_at: System.system_time(:millisecond),
        error_message: error_reason
    }

    state = update_job(failed_job, state)
    state = move_job_to_history(failed_job, state)
    state = add_to_dead_letter_queue(failed_job, state)

    Logger.error("Job failed permanently: #{job_id} - #{error_reason}")

    maybe_alert_critical_job_failure(job, error_reason)

    # Send telemetry
    :telemetry.execute([:flame, :job, :failed], %{}, %{
      job_id: job_id,
      error_reason: error_reason,
      retry_count: job.retry_count
    })

    state
  end

  defp maybe_alert_critical_job_failure(job, error_reason) do
    if job.priority <= @priority_high do
      AlertManager.trigger_manual_alert(%{
        name: "Critical Job Failed",
        severity: 2,
        description: "Critical job #{job.name} failed: #{error_reason}",
        tags: ["job", "failure", "critical"]
      })
    end
  end

  defp initialize_job_queues do
    %{
      critical: :queue.new(),
      high: :queue.new(),
      normal: :queue.new(),
      low: :queue.new(),
      batch: :queue.new()
    }
  end

  defp initialize_retry_policies(opts) do
    %{
      max_retries: Keyword.get(opts, :max_retries, @max_retries),
      base_delay_ms: Keyword.get(opts, :base_retry_delay_ms, 1000),
      max_delay_ms: Keyword.get(opts, :max_retry_delay_ms, 60_000),
      backoff_multiplier: Keyword.get(opts, :backoff_multiplier, 2),
      jitter: Keyword.get(opts, :retry_jitter, true)
    }
  end

  defp load_scheduled_jobs(state, opts) do
    scheduled_jobs = Keyword.get(opts, :scheduled_jobs, [])

    Enum.reduce(scheduled_jobs, state, fn job_config, acc_state ->
      schedule_id = generate_schedule_id()

      scheduler = %{
        id: schedule_id,
        cron_expression: job_config.cron,
        job_spec: job_config.job_spec,
        options: job_config.options || %{},
        created_at: System.system_time(:millisecond),
        enabled: true,
        last_execution: nil,
        next_execution: calculate_next_execution(job_config.cron)
      }

      put_in(acc_state.schedulers[schedule_id], scheduler)
    end)
  end

  defp schedule_queue_processing do
    Process.send_after(self(), :process_queues, @queue_process_interval)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_jobs, @cleanup_interval)
  end

  defp schedule_metrics_collection do
    Process.send_after(self(), :collect_metrics, @metrics_interval)
  end

  defp schedule_job_checking do
    # Check every minute
    Process.send_after(self(), :check_scheduled_jobs, 60_000)
  end

  defp validate_job_spec(job_spec) do
    required_fields = [:name, :function]

    case Enum.all?(required_fields, &Map.has_key?(job_spec, &1)) do
      true ->
        # Additional validation
        if is_function(job_spec.function) or is_tuple(job_spec.function) do
          :ok
        else
          {:error, :invalid_function}
        end

      false ->
        {:error, :missing_required_fields}
    end
  end

  defp validate_workflow_spec(workflow_spec) do
    required_fields = [:name, :steps]

    case Enum.all?(required_fields, &Map.has_key?(workflow_spec, &1)) do
      true ->
        if is_list(workflow_spec.steps) and workflow_spec.steps != [] do
          validate_workflow_steps(workflow_spec.steps)
        else
          {:error, :invalid_steps}
        end

      false ->
        {:error, :missing_required_fields}
    end
  end

  defp validate_workflow_steps(steps) do
    # Validate that all steps have required fields and dependencies are valid
    step_ids = Enum.map(steps, & &1.id)

    invalid_step =
      Enum.find(steps, fn step ->
        not Map.has_key?(step, :id) or
          not Map.has_key?(step, :job_spec) or
          (Map.has_key?(step, :depends_on) and not Enum.all?(step.depends_on, &(&1 in step_ids)))
      end)

    if invalid_step do
      {:error, {:invalid_step, invalid_step.id}}
    else
      :ok
    end
  end

  defp validate_cron_expression(cron_expression) do
    # Basic cron validation - in production would use a proper cron parser
    if is_binary(cron_expression) and String.match?(cron_expression, ~r/^[\d\*\/\-\,\s]+$/) do
      :ok
    else
      {:error, :invalid_cron_expression}
    end
  end

  defp validate_job_template(template_spec) do
    required_fields = [:name, :function]

    case Enum.all?(required_fields, &Map.has_key?(template_spec, &1)) do
      true -> :ok
      false -> {:error, :missing_required_fields}
    end
  end

  defp create_job_from_spec(job_spec, options) do
    job_id = generate_job_id()
    priority = Map.get(options, :priority, @priority_normal)
    queue = priority_to_queue(priority)

    %{
      id: job_id,
      name: job_spec.name,
      function: job_spec.function,
      parameters: Map.get(job_spec, :parameters, %{}),
      requirements: Map.get(job_spec, :requirements, %{}),
      priority: priority,
      queue: queue,
      state: @state_pending,
      created_at: System.system_time(:millisecond),
      started_at: nil,
      completed_at: nil,
      retry_count: 0,
      max_retries: Map.get(options, :max_retries, @max_retries),
      timeout_ms: Map.get(options, :timeout_ms, @default_timeout),
      progress: 0,
      result: nil,
      error_message: nil,
      execution_pid: nil,
      resource_usage: %{},
      metadata: Map.get(options, :metadata, %{}),
      template_id: Map.get(options, :template_id)
    }
  end

  defp create_workflow_from_spec(workflow_spec, options) do
    workflow_id = generate_workflow_id()

    # Process workflow steps and build dependency graph
    steps =
      Enum.map(workflow_spec.steps, fn step_spec ->
        %{
          id: step_spec.id,
          name: step_spec.name || step_spec.id,
          job_spec: step_spec.job_spec,
          depends_on: Map.get(step_spec, :depends_on, []),
          condition: Map.get(step_spec, :condition),
          state: @state_pending,
          job_id: nil,
          started_at: nil,
          completed_at: nil,
          result: nil,
          error_message: nil
        }
      end)

    %{
      id: workflow_id,
      name: workflow_spec.name,
      description: Map.get(workflow_spec, :description, ""),
      steps: steps,
      state: @state_pending,
      created_at: System.system_time(:millisecond),
      started_at: nil,
      completed_at: nil,
      current_step: nil,
      metadata: Map.get(options, :metadata, %{})
    }
  end

  defp enqueue_job(job, state) do
    queue_name = job.queue
    updated_queue = :queue.in(job.id, state.job_queues[queue_name])

    state = %{
      state
      | job_queues: Map.put(state.job_queues, queue_name, updated_queue),
        active_jobs: Map.put(state.active_jobs, job.id, %{job | state: @state_queued})
    }

    state
  end

  defp process_all_queues(state) do
    # Process queues in priority order
    queue_order = [:critical, :high, :normal, :low, :batch]

    Enum.reduce(queue_order, state, fn queue_name, acc_state ->
      process_queue(queue_name, acc_state)
    end)
  end

  defp process_queue(queue_name, state) do
    queue = state.job_queues[queue_name]

    # Check if we can execute more jobs (resource constraints)
    case can_execute_more_jobs(queue_name, state) do
      false ->
        state

      true ->
        case :queue.out(queue) do
          {{:value, job_id}, updated_queue} ->
            process_dequeued_job(queue_name, job_id, updated_queue, state)

          {:empty, _} ->
            # Queue is empty
            state
        end
    end
  end

  defp process_dequeued_job(queue_name, job_id, updated_queue, state) do
    case Map.get(state.active_jobs, job_id) do
      nil ->
        # Job was deleted, continue processing
        process_queue(queue_name, %{
          state
          | job_queues: Map.put(state.job_queues, queue_name, updated_queue)
        })

      job when job.state == @state_queued ->
        # Execute the job
        state = %{
          state
          | job_queues: Map.put(state.job_queues, queue_name, updated_queue)
        }

        state = execute_job(job, state)

        # Continue processing this queue
        process_queue(queue_name, state)

      _ ->
        # Job is not in queued state, continue
        process_queue(queue_name, %{
          state
          | job_queues: Map.put(state.job_queues, queue_name, updated_queue)
        })
    end
  end

  defp can_execute_more_jobs(queue_name, state) do
    # Check resource constraints and concurrent job limits
    running_jobs_count = count_running_jobs(state)
    max_concurrent_jobs = get_max_concurrent_jobs(queue_name)

    # Check cluster capacity
    try do
      case GenServer.call(ClusterManager, {:select_cluster, %{}}, 5000) do
        {:ok, _cluster} ->
          running_jobs_count < max_concurrent_jobs

        {:error, :no_healthy_clusters} ->
          false
      end
    catch
      _ -> false
    end
  end

  defp execute_job(job, state) do
    Logger.info("Executing job: #{job.id} (#{job.name})")

    # Update job state
    running_job = %{job | state: @state_running, started_at: System.system_time(:millisecond)}

    # Start job execution
    execution_pid = spawn_job_execution(running_job)
    running_job = %{running_job | execution_pid: execution_pid}

    # Schedule timeout check
    if running_job.timeout_ms do
      Process.send_after(self(), {:job_timeout, running_job.id}, running_job.timeout_ms)
    end

    update_job(running_job, state)
  end

  defp spawn_job_execution(job) do
    parent = self()

    spawn_link(fn ->
      try do
        # Validate job security before execution
        case SecurityManager.validate_function(job.function, %{}) do
          :ok ->
            # Execute the job function
            result =
              case job.function do
                fun when is_function(fun) ->
                  fun.(job.parameters)

                {module, function, args} ->
                  apply(module, function, [job.parameters | args])

                _ ->
                  {:error, "Invalid function specification"}
              end

            send(parent, {:job_completed, job.id, result})

          {:error, reason} ->
            send(parent, {:job_failed, job.id, "Security validation failed: #{reason}"})
        end
      rescue
        error ->
          send(parent, {:job_failed, job.id, "Execution error: #{inspect(error)}"})
      catch
        :exit, reason ->
          send(parent, {:job_failed, job.id, "Process exited: #{inspect(reason)}"})
      end
    end)
  end

  defp start_workflow_execution(workflow, state) do
    # Start workflow by identifying and executing initial steps (those with no dependencies)
    initial_steps =
      Enum.filter(workflow.steps, fn step ->
        step.depends_on == []
      end)

    if initial_steps != [] do
      started_workflow = %{
        workflow
        | state: @state_running,
          started_at: System.system_time(:millisecond)
      }

      state = put_in(state.workflows[workflow.id], started_workflow)

      # Execute initial steps
      Enum.reduce(initial_steps, state, fn step, acc_state ->
        execute_workflow_step(started_workflow.id, step, acc_state)
      end)
    else
      # No initial steps found - invalid workflow
      failed_workflow = %{
        workflow
        | state: @state_failed,
          completed_at: System.system_time(:millisecond)
      }

      put_in(state.workflows[workflow.id], failed_workflow)
    end
  end

  defp execute_workflow_step(workflow_id, step, state) do
    # Create and submit a job for this workflow step
    job_spec = step.job_spec

    options = %{
      metadata: %{
        workflow_id: workflow_id,
        workflow_step: step.id
      }
    }

    job = create_job_from_spec(job_spec, options)

    # Update workflow step with job ID
    state =
      update_in(state.workflows[workflow_id].steps, fn steps ->
        Enum.map(steps, &mark_step_running(&1, step.id, job.id))
      end)

    # Enqueue the job
    enqueue_job(job, state)
  end

  defp mark_step_running(s, step_id, job_id) do
    if s.id == step_id do
      %{
        s
        | job_id: job_id,
          state: @state_running,
          started_at: System.system_time(:millisecond)
      }
    else
      s
    end
  end

  defp check_workflow_completion(completed_job, state) do
    # Check if this job completion affects any workflows
    case get_in(completed_job.metadata, [:workflow_id]) do
      nil ->
        state

      workflow_id ->
        case Map.get(state.workflows, workflow_id) do
          nil ->
            state

          _workflow ->
            step_id = get_in(completed_job.metadata, [:workflow_step])

            # Update workflow step completion
            state = update_workflow_step_completion(workflow_id, step_id, completed_job, state)

            # Check if we can execute next steps
            execute_next_workflow_steps(workflow_id, state)
        end
    end
  end

  defp update_workflow_step_completion(workflow_id, step_id, completed_job, state) do
    update_in(state.workflows[workflow_id].steps, fn steps ->
      Enum.map(steps, &apply_step_completion(&1, step_id, completed_job))
    end)
  end

  defp apply_step_completion(step, step_id, completed_job) do
    if step.id == step_id do
      %{
        step
        | state: completed_job.state,
          completed_at: completed_job.completed_at,
          result: completed_job.result,
          error_message: completed_job.error_message
      }
    else
      step
    end
  end

  defp execute_next_workflow_steps(workflow_id, state) do
    workflow = Map.get(state.workflows, workflow_id)

    # Find steps that can now be executed (all dependencies completed)
    ready_steps =
      Enum.filter(workflow.steps, fn step ->
        step.state == @state_pending and
          Enum.all?(step.depends_on, fn dep_id ->
            dep_step = Enum.find(workflow.steps, &(&1.id == dep_id))
            dep_step && dep_step.state == @state_completed
          end)
      end)

    # Execute ready steps
    state =
      Enum.reduce(ready_steps, state, fn step, acc_state ->
        # Check conditional execution if defined
        if should_execute_step(step, workflow) do
          execute_workflow_step(workflow_id, step, acc_state)
        else
          # Skip step
          skip_workflow_step(workflow_id, step, acc_state)
        end
      end)

    # Check if workflow is complete
    check_workflow_final_completion(workflow_id, state)
  end

  defp should_execute_step(step, workflow) do
    case step.condition do
      nil ->
        true

      condition when is_function(condition) ->
        condition.(workflow)

      _ ->
        true
    end
  end

  defp skip_workflow_step(workflow_id, step, state) do
    update_in(state.workflows[workflow_id].steps, fn steps ->
      Enum.map(steps, &mark_step_skipped(&1, step.id))
    end)
  end

  defp mark_step_skipped(s, step_id) do
    if s.id == step_id do
      %{
        s
        | state: @state_completed,
          started_at: System.system_time(:millisecond),
          completed_at: System.system_time(:millisecond),
          result: :skipped
      }
    else
      s
    end
  end

  defp check_workflow_final_completion(workflow_id, state) do
    workflow = Map.get(state.workflows, workflow_id)

    all_completed =
      Enum.all?(workflow.steps, fn step ->
        step.state in [@state_completed, @state_failed]
      end)

    if all_completed do
      # Determine final workflow state
      final_state =
        if Enum.any?(workflow.steps, &(&1.state == @state_failed)) do
          @state_failed
        else
          @state_completed
        end

      completed_workflow = %{
        workflow
        | state: final_state,
          completed_at: System.system_time(:millisecond)
      }

      state = put_in(state.workflows[workflow_id], completed_workflow)

      Logger.info("Workflow #{final_state}: #{workflow_id} (#{workflow.name})")

      # Send telemetry
      :telemetry.execute(
        [:flame, :workflow, final_state],
        %{
          duration_ms: completed_workflow.completed_at - completed_workflow.started_at
        },
        %{
          workflow_id: workflow_id,
          steps_count: length(workflow.steps)
        }
      )

      state
    else
      state
    end
  end

  # Helper functions

  defp generate_job_id, do: "job-#{System.system_time(:millisecond)}-#{:rand.uniform(9999)}"

  defp generate_workflow_id,
    do: "workflow-#{System.system_time(:millisecond)}-#{:rand.uniform(9999)}"

  defp generate_schedule_id,
    do: "schedule-#{System.system_time(:millisecond)}-#{:rand.uniform(9999)}"

  defp generate_template_id,
    do: "template-#{System.system_time(:millisecond)}-#{:rand.uniform(9999)}"

  defp priority_to_queue(@priority_critical), do: :critical
  defp priority_to_queue(@priority_high), do: :high
  defp priority_to_queue(@priority_normal), do: :normal
  defp priority_to_queue(@priority_low), do: :low
  defp priority_to_queue(@priority_batch), do: :batch
  defp priority_to_queue(_), do: :normal

  defp get_max_concurrent_jobs(:critical), do: 10
  defp get_max_concurrent_jobs(:high), do: 20
  defp get_max_concurrent_jobs(:normal), do: 50
  defp get_max_concurrent_jobs(:low), do: 100
  defp get_max_concurrent_jobs(:batch), do: 200

  defp count_running_jobs(state) do
    state.active_jobs
    |> Enum.count(fn {_id, job} -> job.state == @state_running end)
  end

  defp find_job(job_id, state) do
    case Map.get(state.active_jobs, job_id) do
      nil ->
        # Check job history
        Enum.find(state.job_history, &(&1.id == job_id))

      job ->
        job
    end
  end

  defp get_all_jobs(state) do
    active_jobs = Map.values(state.active_jobs)
    active_jobs ++ state.job_history
  end

  defp apply_job_filters(jobs, filters) do
    Enum.filter(jobs, fn job ->
      Enum.all?(filters, &job_matches_filter?(job, &1))
    end)
  end

  defp job_matches_filter?(job, {key, value}) do
    case key do
      :state -> job.state == value
      :priority -> job.priority == value
      :queue -> job.queue == value
      :name -> String.contains?(job.name, value)
      _ -> true
    end
  end

  defp update_job(job, state) do
    %{state | active_jobs: Map.put(state.active_jobs, job.id, job)}
  end

  defp move_job_to_history(job, state) do
    %{
      state
      | active_jobs: Map.delete(state.active_jobs, job.id),
        job_history: [job | state.job_history]
    }
  end

  defp calculate_job_duration(job) do
    cond do
      job.completed_at && job.started_at ->
        job.completed_at - job.started_at

      job.started_at ->
        System.system_time(:millisecond) - job.started_at

      true ->
        nil
    end
  end

  defp should_retry_job(job, retry_policies) do
    job.retry_count < retry_policies.max_retries and
      job.state != @state_cancelled
  end

  defp calculate_next_retry(job, retry_policies) do
    base_delay = retry_policies.base_delay_ms
    backoff_multiplier = retry_policies.backoff_multiplier
    max_delay = retry_policies.max_delay_ms

    delay = min(base_delay * :math.pow(backoff_multiplier, job.retry_count), max_delay)

    # Add jitter if enabled
    final_delay =
      if retry_policies.jitter do
        jitter_range = trunc(delay * 0.1)
        delay + :rand.uniform(jitter_range * 2) - jitter_range
      else
        delay
      end

    System.system_time(:millisecond) + trunc(final_delay)
  end

  defp schedule_job_retry(job) do
    Process.send_after(
      self(),
      {:retry_job, job.id},
      job.next_retry_at - System.system_time(:millisecond)
    )
  end

  defp add_to_dead_letter_queue(job, state) do
    updated_dlq = :queue.in(job, state.dead_letter_queue)
    %{state | dead_letter_queue: updated_dlq}
  end

  defp enqueue_job_for_execution(job, state) do
    queue_name = job.queue
    updated_queue = :queue.in(job.id, state.job_queues[queue_name])
    %{state | job_queues: Map.put(state.job_queues, queue_name, updated_queue)}
  end

  defp format_workflow_step(step) do
    %{
      id: step.id,
      name: step.name,
      state: step.state,
      depends_on: step.depends_on,
      job_id: step.job_id,
      started_at: step.started_at,
      completed_at: step.completed_at,
      duration_ms:
        if(step.completed_at && step.started_at,
          do: step.completed_at - step.started_at,
          else: nil
        )
    }
  end

  defp calculate_workflow_progress(workflow) do
    completed_steps = Enum.count(workflow.steps, &(&1.state == @state_completed))
    total_steps = length(workflow.steps)

    if total_steps > 0 do
      round(completed_steps / total_steps * 100)
    else
      0
    end
  end

  defp calculate_next_execution(_cron_expression) do
    # Simplified - in production would use a proper cron library
    # Next minute
    System.system_time(:millisecond) + 60_000
  end

  defp check_and_execute_scheduled_jobs(state) do
    current_time = System.system_time(:millisecond)

    Enum.reduce(state.schedulers, state, fn {schedule_id, scheduler}, acc_state ->
      if scheduler.enabled and scheduler.next_execution <= current_time do
        # Execute scheduled job
        job = create_job_from_spec(scheduler.job_spec, scheduler.options)
        acc_state = enqueue_job(job, acc_state)

        # Update scheduler
        updated_scheduler = %{
          scheduler
          | last_execution: current_time,
            next_execution: calculate_next_execution(scheduler.cron_expression)
        }

        put_in(acc_state.schedulers[schedule_id], updated_scheduler)
      else
        acc_state
      end
    end)
  end

  defp cleanup_completed_jobs(state) do
    # Remove old completed jobs from history (keep last 1000)
    max_history = 1000

    updated_history =
      state.job_history
      |> Enum.sort_by(& &1.completed_at, :desc)
      |> Enum.take(max_history)

    %{state | job_history: updated_history}
  end

  defp collect_and_report_metrics(state) do
    metrics = calculate_job_metrics(state)

    # Send telemetry for monitoring systems
    :telemetry.execute([:flame, :job_manager, :metrics], metrics, %{
      timestamp: System.system_time(:millisecond)
    })
  end

  defp calculate_job_metrics(state) do
    all_jobs = get_all_jobs(state)
    active_jobs = Map.values(state.active_jobs)

    %{
      total_jobs: length(all_jobs),
      active_jobs: length(active_jobs),
      jobs_by_state: calculate_jobs_by_state(all_jobs),
      jobs_by_priority: calculate_jobs_by_priority(all_jobs),
      queue_sizes: calculate_queue_sizes(state.job_queues),
      average_execution_time: calculate_average_execution_time(all_jobs),
      job_throughput_per_hour: calculate_job_throughput(all_jobs),
      workflow_metrics: calculate_workflow_metrics(state.workflows),
      dead_letter_queue_size: :queue.len(state.dead_letter_queue)
    }
  end

  defp calculate_jobs_by_state(jobs) do
    Enum.group_by(jobs, & &1.state)
    |> Enum.map(fn {state, job_list} -> {state, length(job_list)} end)
    |> Enum.into(%{})
  end

  defp calculate_jobs_by_priority(jobs) do
    Enum.group_by(jobs, & &1.priority)
    |> Enum.map(fn {priority, job_list} -> {priority, length(job_list)} end)
    |> Enum.into(%{})
  end

  defp calculate_queue_sizes(job_queues) do
    Enum.map(job_queues, fn {queue_name, queue} ->
      {queue_name, :queue.len(queue)}
    end)
    |> Enum.into(%{})
  end

  defp calculate_average_execution_time(jobs) do
    completed_jobs = Enum.filter(jobs, &(&1.state == @state_completed))

    completed_count = Enum.count(completed_jobs)

    if completed_count > 0 do
      total_time = Enum.sum(Enum.map(completed_jobs, &calculate_job_duration/1))
      total_time / completed_count
    else
      0
    end
  end

  defp calculate_job_throughput(jobs) do
    one_hour_ago = System.system_time(:millisecond) - 3_600_000

    recent_completed =
      Enum.count(jobs, fn job ->
        job.state == @state_completed and job.completed_at >= one_hour_ago
      end)

    recent_completed
  end

  defp calculate_workflow_metrics(workflows) do
    workflow_list = Map.values(workflows)

    %{
      total_workflows: length(workflow_list),
      workflows_by_state: calculate_jobs_by_state(workflow_list),
      average_workflow_duration: calculate_average_execution_time(workflow_list)
    }
  end
end
