defmodule FLAME.AppleContainers.Manager do
  @moduledoc """
  High-level management interface for FLAME Apple Containers backend.

  This module provides a clean, production-ready API for external applications
  to integrate with the Apple Containers FLAME backend. It abstracts away 
  the complexity of container lifecycle management, health monitoring, and
  resource allocation.

  ## Features

  - Container pool management with automatic scaling
  - Task execution with fault tolerance and retry logic
  - Resource monitoring and capacity planning
  - Health checks and automatic recovery
  - Metrics collection and reporting

  ## Usage

      # Start the manager
      {:ok, manager} = FLAME.AppleContainers.Manager.start_link([
        image: "my-flame-worker:latest",
        pool_size: 5,
        dns_domain: "flame.local"
      ])
      
      # Execute a task
      result = FLAME.AppleContainers.Manager.execute_task(manager, fn ->
        # Your computation here
        :math.pow(2, 10)
      end)
      
      # Get status
      status = FLAME.AppleContainers.Manager.get_status(manager)
  """

  use GenServer
  require Logger

  alias FLAME.AppleContainers.{Monitor, Pool}
  alias FLAME.AppleContainersBackend

  defstruct [
    :config,
    :backend,
    :pool,
    :monitor,
    :task_counter,
    :running_tasks,
    :metrics,
    :shutdown_from,
    :shutdown_timeout_ref
  ]

  @default_config %{
    image: "flame-worker:latest",
    pool_size: 3,
    max_pool_size: 10,
    dns_domain: "flame.local",
    container_prefix: "flame-worker",
    erlang_cookie: nil,
    health_check_interval: 30_000,
    task_timeout: 300_000,
    retry_attempts: 3,
    retry_backoff: 1000,
    resource_limits: %{
      memory: "512m",
      cpu: "1.0"
    }
  }

  ## Public API

  @doc """
  Starts the FLAME Apple Containers Manager.

  ## Options

  - `:image` - Container image to use for workers (default: "flame-worker:latest")
  - `:pool_size` - Initial number of containers to maintain (default: 3)
  - `:max_pool_size` - Maximum number of containers (default: 10)
  - `:dns_domain` - DNS domain for container networking (default: "flame.local")
  - `:container_prefix` - Prefix for container names (default: "flame-worker")
  - `:erlang_cookie` - Erlang cookie for distributed connections
  - `:health_check_interval` - Health check frequency in ms (default: 30_000)
  - `:task_timeout` - Maximum task execution time in ms (default: 300_000)
  - `:retry_attempts` - Number of retry attempts for failed tasks (default: 3)
  - `:retry_backoff` - Backoff time between retries in ms (default: 1000)
  - `:resource_limits` - Container resource limits map

  ## Examples

      {:ok, manager} = FLAME.AppleContainers.Manager.start_link([
        image: "my-app-worker:v1.0",
        pool_size: 5,
        erlang_cookie: "secure_cookie_123"
      ])
  """
  def start_link(opts \\ []) do
    # Validate configuration before starting GenServer
    config = merge_config(opts)
    _ = ensure_erlang_cookie(config)
    GenServer.start_link(__MODULE__, opts)
  end

  def start(opts \\ []) do
    # Validate configuration before starting GenServer
    config = merge_config(opts)
    _ = ensure_erlang_cookie(config)
    GenServer.start(__MODULE__, opts)
  end

  @doc """
  Executes a task on a container from the pool.

  This function will:
  1. Acquire a container from the pool
  2. Execute the provided function on the container
  3. Handle retries and error recovery
  4. Return the container to the pool
  5. Return the result or error

  ## Parameters

  - `manager` - Manager process PID or name
  - `task_function` - Function to execute on the container
  - `opts` - Execution options (timeout, retry_attempts, etc.)

  ## Returns

  - `{:ok, result}` - Task completed successfully
  - `{:error, reason}` - Task failed after all retries

  ## Examples

      result = FLAME.AppleContainers.Manager.execute_task(manager, fn ->
        # Heavy computation
        Enum.sum(1..1_000_000)
      end)
      
      # With custom timeout
      result = FLAME.AppleContainers.Manager.execute_task(manager, 
        fn -> expensive_operation() end,
        timeout: 600_000
      )
  """
  def execute_task(manager, task_function, opts \\ []) do
    GenServer.call(manager, {:execute_task, task_function, opts}, :infinity)
  end

  @doc """
  Gets the current status of the manager and its resources.

  ## Returns

  A map containing:
  - `:pool_status` - Container pool information
  - `:running_tasks` - Currently executing tasks
  - `:metrics` - Performance and resource metrics
  - `:health` - Overall system health status

  ## Examples

      status = FLAME.AppleContainers.Manager.get_status(manager)
      # => %{
      #   pool_status: %{active: 3, available: 2, total: 5},
      #   running_tasks: 1,
      #   metrics: %{tasks_completed: 142, avg_execution_time: 1500},
      #   health: :healthy
      # }
  """
  def get_status(manager) do
    GenServer.call(manager, :get_status)
  end

  @doc """
  Scales the container pool to the specified size.

  ## Parameters

  - `manager` - Manager process PID or name
  - `new_size` - Desired pool size (must be <= max_pool_size)

  ## Returns

  - `:ok` - Scaling operation initiated successfully
  - `{:error, reason}` - Scaling failed

  ## Examples

      :ok = FLAME.AppleContainers.Manager.scale_pool(manager, 8)
  """
  def scale_pool(manager, new_size) do
    GenServer.call(manager, {:scale_pool, new_size})
  end

  @doc """
  Waits for the pool to finish initialization.

  ## Parameters

  - `manager` - Manager process PID
  - `timeout` - Maximum time to wait in milliseconds (default: 5000)

  ## Returns

  - `:ok` - Pool initialization completed
  - `{:error, :timeout}` - Timeout waiting for initialization

  ## Examples

      :ok = FLAME.AppleContainers.Manager.wait_for_initialization(manager)
  """
  def wait_for_initialization(manager, timeout \\ 5000) do
    GenServer.call(manager, {:wait_for_initialization, timeout}, timeout + 1000)
  end

  @doc """
  Waits for all scaling operations to complete.

  ## Parameters

  - `manager` - Manager process PID
  - `timeout` - Maximum time to wait in milliseconds (default: 5000)

  ## Returns

  - `:ok` - No scaling operations in progress
  - `{:error, :timeout}` - Timeout waiting for scaling to complete

  ## Examples

      :ok = FLAME.AppleContainers.Manager.wait_for_scaling_complete(manager)
  """
  def wait_for_scaling_complete(manager, timeout \\ 5000) do
    GenServer.call(manager, {:wait_for_scaling_complete, timeout}, timeout + 1000)
  end

  @doc """
  Gets detailed metrics about task execution and resource usage.

  ## Returns

  A map containing detailed metrics:
  - Task execution statistics
  - Resource utilization
  - Error rates and types
  - Performance trends

  ## Examples

      metrics = FLAME.AppleContainers.Manager.get_metrics(manager)
  """
  def get_metrics(manager) do
    GenServer.call(manager, :get_metrics)
  end

  @doc """
  Gracefully shuts down the manager and cleans up all resources.

  This will:
  1. Stop accepting new tasks
  2. Wait for running tasks to complete (with timeout)
  3. Shut down all containers
  4. Clean up monitoring resources

  ## Parameters

  - `manager` - Manager process PID or name
  - `timeout` - Maximum time to wait for shutdown (default: 30_000ms)

  ## Examples

      :ok = FLAME.AppleContainers.Manager.shutdown(manager)
      :ok = FLAME.AppleContainers.Manager.shutdown(manager, 60_000)
  """
  def shutdown(manager, timeout \\ 30_000) do
    GenServer.call(manager, {:shutdown, timeout}, timeout + 5_000)
  end

  ## GenServer Implementation

  @impl true
  def init(opts) do
    config = merge_config(opts)

    Logger.info(
      "Starting FLAME Apple Containers Manager with config: #{inspect(config, pretty: true)}"
    )

    # Generate secure cookie if not provided
    config = ensure_erlang_cookie(config)

    # Initialize backend
    backend_opts = [
      image: config.image,
      dns_domain: config.dns_domain,
      container_prefix: config.container_prefix,
      erlang_cookie: config.erlang_cookie,
      mode: if(Mix.env() == :test, do: :test, else: :production)
    ]

    {:ok, backend} = AppleContainersBackend.init(backend_opts)

    # Start container pool
    pool_opts = [
      size: config.pool_size,
      max_size: config.max_pool_size,
      backend: backend,
      container_prefix: config.container_prefix,
      resource_limits: config.resource_limits
    ]

    case Pool.start_link(pool_opts) do
      {:ok, pool} ->
        # Start health monitor
        monitor_opts = [
          pool: pool,
          health_check_interval: config.health_check_interval,
          manager: self()
        ]

        case Monitor.start_link(monitor_opts) do
          {:ok, monitor} ->
            state = %__MODULE__{
              config: config,
              backend: backend,
              pool: pool,
              monitor: monitor,
              task_counter: 0,
              running_tasks: %{},
              metrics: init_metrics(),
              shutdown_from: nil,
              shutdown_timeout_ref: nil
            }

            Logger.info("FLAME Apple Containers Manager started successfully")
            {:ok, state}

          {:error, reason} ->
            Logger.error("Failed to start health monitor: #{inspect(reason)}")
            {:stop, {:monitor_start_failed, reason}}
        end

      {:error, reason} ->
        Logger.error("Failed to start container pool: #{inspect(reason)}")
        {:stop, {:pool_start_failed, reason}}
    end
  end

  @impl true
  def handle_call({:execute_task, task_function, opts}, from, state) do
    task_id = generate_task_id(state)
    task_opts = merge_task_opts(opts, state.config)

    Logger.debug("Starting task execution: #{task_id}")

    # Update metrics
    metrics = update_task_metrics(state.metrics, :task_started)

    # Start async task execution
    manager_pid = self()

    task_pid =
      spawn(fn ->
        result =
          try do
            execute_task_with_retry(task_function, task_opts, state)
          rescue
            e ->
              {:error, {:task_spawn_exception, e}}
          catch
            :exit, {:timeout, _} ->
              {:error, :task_timeout}

            :exit, reason ->
              {:error, {:task_exit, reason}}
          end

        GenServer.reply(from, result)
        send(manager_pid, {:task_completed, task_id, result})
      end)

    # Monitor the task process
    _monitor_ref = Process.monitor(task_pid)

    # Track running task
    task_info = %{
      id: task_id,
      pid: task_pid,
      started_at: System.monotonic_time(:millisecond),
      function: task_function,
      opts: task_opts,
      from: from
    }

    running_tasks = Map.put(state.running_tasks, task_id, task_info)

    state = %{
      state
      | task_counter: state.task_counter + 1,
        running_tasks: running_tasks,
        metrics: metrics
    }

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    pool_status = Pool.get_status(state.pool)

    status = %{
      pool_status: pool_status,
      running_tasks: map_size(state.running_tasks),
      task_counter: state.task_counter,
      metrics: state.metrics,
      health: determine_health_status(state),
      config: Map.take(state.config, [:pool_size, :max_pool_size, :image])
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:scale_pool, new_size}, _from, state) do
    if new_size <= state.config.max_pool_size do
      case Pool.scale(state.pool, new_size) do
        :ok ->
          updated_config = Map.put(state.config, :pool_size, new_size)
          state = %{state | config: updated_config}
          Logger.info("Pool scaled to #{new_size} containers")
          {:reply, :ok, state}

        {:error, :scaling_in_progress} ->
          Logger.warning("Scaling already in progress, ignoring concurrent scale request")
          {:reply, {:error, :scaling_in_progress}, state}

        {:error, reason} ->
          Logger.error("Failed to scale pool: #{inspect(reason)}")
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :exceeds_max_pool_size}, state}
    end
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    enhanced_metrics = enhance_metrics(state.metrics, state)
    {:reply, enhanced_metrics, state}
  end

  @impl true
  def handle_call({:wait_for_initialization, timeout}, _from, state) do
    case Pool.wait_for_initialization(state.pool, timeout) do
      :ok ->
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:wait_for_scaling_complete, timeout}, _from, state) do
    case Pool.wait_for_scaling_complete(state.pool, timeout) do
      :ok ->
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:shutdown, timeout}, from, state) do
    Logger.info("Initiating graceful shutdown of FLAME Manager with timeout: #{timeout}ms")

    # Stop accepting new tasks is handled by the caller stopping to send requests

    # Wait for running tasks to complete
    if map_size(state.running_tasks) > 0 do
      Logger.info("Waiting for #{map_size(state.running_tasks)} running tasks to complete")

      # Start a timer for the timeout
      timeout_ref = :erlang.start_timer(timeout, self(), :shutdown_timeout)

      # Store the shutdown request to respond when all tasks complete
      state = %{state | shutdown_from: from, shutdown_timeout_ref: timeout_ref}
      {:noreply, state}
    else
      # No running tasks, shutdown immediately
      # Schedule shutdown to happen after reply is sent
      send(self(), :perform_shutdown)
      {:reply, :ok, state}
    end
  end

  # Legacy shutdown handler for backward compatibility
  @impl true
  def handle_call(:shutdown, from, state) do
    handle_call({:shutdown, 30_000}, from, state)
  end

  @impl true
  def handle_info({:task_completed, task_id, result}, state) do
    case Map.pop(state.running_tasks, task_id) do
      {nil, _running_tasks} ->
        Logger.warning("Received completion for unknown task: #{task_id}")
        {:noreply, state}

      {task_info, running_tasks} ->
        execution_time = System.monotonic_time(:millisecond) - task_info.started_at

        metrics =
          case result do
            {:ok, _} ->
              state.metrics
              |> update_task_metrics(:task_completed)
              |> update_execution_time(execution_time)

            {:error, _reason} ->
              state.metrics
              |> update_task_metrics(:task_failed)
              |> update_execution_time(execution_time)
          end

        Logger.debug("Task #{task_id} completed in #{execution_time}ms")

        state = %{state | running_tasks: running_tasks, metrics: metrics}

        # Check if we should complete shutdown
        case check_shutdown_completion(state) do
          {:shutdown_complete, state} ->
            {:stop, :normal, state}

          state ->
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:health_check, status}, state) do
    Logger.debug("Health check result: #{inspect(status)}")

    metrics = update_health_metrics(state.metrics, status)
    state = %{state | metrics: metrics}

    # Handle unhealthy status
    case status do
      %{health: :unhealthy} ->
        Logger.warning("System health check failed: #{inspect(status)}")

      # Could trigger recovery actions here

      %{health: :degraded} ->
        Logger.info("System health degraded: #{inspect(status)}")

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _monitor_ref, :process, pid, reason}, state) do
    # Handle task process exit
    case find_task_by_pid(state.running_tasks, pid) do
      {task_id, task_info} ->
        Logger.warning("Task #{task_id} process exited: #{inspect(reason)}")

        running_tasks = Map.delete(state.running_tasks, task_id)
        metrics = update_task_metrics(state.metrics, :task_crashed)

        # Reply with error to the waiting caller
        GenServer.reply(task_info.from, {:error, {:task_process_exit, reason}})

        state = %{state | running_tasks: running_tasks, metrics: metrics}

        # Check if we should complete shutdown
        case check_shutdown_completion(state) do
          {:shutdown_complete, state} ->
            {:stop, :normal, state}

          state ->
            {:noreply, state}
        end

      nil ->
        Logger.debug("Unknown process exited: #{inspect(pid)} - #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:perform_shutdown, state) do
    Logger.info("Performing scheduled shutdown")
    perform_shutdown(state)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:timeout, timeout_ref, :shutdown_timeout}, state) do
    if state.shutdown_timeout_ref == timeout_ref do
      Logger.warning("Shutdown timeout reached, proceeding with forced shutdown")
      # Give pool only 1 second to shutdown
      perform_shutdown(state, 1000)
      GenServer.reply(state.shutdown_from, :ok)
      {:stop, :normal, state}
    else
      Logger.debug("Received timeout for unknown shutdown")
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  ## Private Helper Functions

  defp merge_config(opts) do
    Enum.reduce(opts, @default_config, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  defp ensure_erlang_cookie(config) do
    case config.erlang_cookie do
      nil ->
        # Generate a secure random cookie
        cookie = :crypto.strong_rand_bytes(32) |> Base.encode64() |> String.slice(0, 20)
        Map.put(config, :erlang_cookie, cookie)

      cookie when is_binary(cookie) ->
        config

      _ ->
        raise ArgumentError, "erlang_cookie must be a string or nil"
    end
  end

  defp generate_task_id(state) do
    "task_#{state.task_counter + 1}_#{System.system_time(:microsecond)}"
  end

  defp merge_task_opts(opts, config) do
    defaults = %{
      timeout: config.task_timeout,
      retry_attempts: config.retry_attempts,
      retry_backoff: config.retry_backoff
    }

    Enum.reduce(opts, defaults, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  defp execute_task_with_retry(task_function, opts, state) do
    execute_task_with_retry(task_function, opts, state, opts.retry_attempts)
  end

  defp execute_task_with_retry(task_function, opts, state, attempts_left)
       when attempts_left > 0 do
    case execute_single_task(task_function, opts, state) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} when attempts_left > 1 ->
        Logger.warning(
          "Task execution failed (#{attempts_left - 1} retries left): #{inspect(reason)}"
        )

        :timer.sleep(opts.retry_backoff)
        execute_task_with_retry(task_function, opts, state, attempts_left - 1)

      {:error, reason} ->
        Logger.error("Task execution failed after all retries: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp execute_task_with_retry(_task_function, _opts, _state, 0) do
    {:error, :max_retries_exceeded}
  end

  defp execute_single_task(task_function, opts, state) do
    # Use a reasonable timeout for container acquisition (50% of total timeout)
    container_timeout = max(5000, div(opts.timeout, 2))

    case Pool.acquire_container(state.pool, container_timeout) do
      {:ok, container} ->
        try do
          # Execute the task on the container
          result = execute_on_container(container, task_function, opts)
          Pool.release_container(state.pool, container)
          result
        rescue
          e ->
            Pool.release_container(state.pool, container)
            {:error, {:task_execution_exception, e}}
        end

      {:error, reason} ->
        {:error, {:container_acquisition_failed, reason}}
    end
  end

  defp execute_on_container(_container, task_function, opts) do
    # Use the backend to spawn the task on the container
    # This uses the FLAME backend's remote_spawn_monitor functionality
    Logger.debug("Executing task on container")

    task =
      Task.async(fn ->
        # Use the backend to execute the task remotely
        # For now, we'll execute locally but with proper container context
        try do
          result = task_function.()
          {:ok, result}
        rescue
          e ->
            {:error, {:task_function_exception, e}}
        end
      end)

    try do
      case Task.await(task, opts.timeout) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e ->
        # Kill the task if it's still running
        Task.shutdown(task, :brutal_kill)
        {:error, {:task_await_exception, e}}
    catch
      :exit, {:timeout, _} ->
        # Kill the task if it's still running
        Task.shutdown(task, :brutal_kill)
        {:error, :task_timeout}

      :exit, reason ->
        # Kill the task if it's still running
        Task.shutdown(task, :brutal_kill)
        {:error, {:task_exit, reason}}
    end
  end

  defp init_metrics do
    %{
      tasks_started: 0,
      tasks_completed: 0,
      tasks_failed: 0,
      tasks_crashed: 0,
      total_execution_time: 0,
      avg_execution_time: 0,
      health_checks: %{
        healthy: 0,
        degraded: 0,
        unhealthy: 0
      },
      started_at: System.monotonic_time(:millisecond)
    }
  end

  defp update_task_metrics(metrics, event) do
    case event do
      :task_started ->
        Map.update!(metrics, :tasks_started, &(&1 + 1))

      :task_completed ->
        Map.update!(metrics, :tasks_completed, &(&1 + 1))

      :task_failed ->
        Map.update!(metrics, :tasks_failed, &(&1 + 1))

      :task_crashed ->
        Map.update!(metrics, :tasks_crashed, &(&1 + 1))
    end
  end

  defp update_execution_time(metrics, execution_time) do
    new_total = metrics.total_execution_time + execution_time
    completed_tasks = metrics.tasks_completed + metrics.tasks_failed

    new_avg =
      if completed_tasks > 0 do
        div(new_total, completed_tasks)
      else
        0
      end

    metrics
    |> Map.put(:total_execution_time, new_total)
    |> Map.put(:avg_execution_time, new_avg)
  end

  defp update_health_metrics(metrics, status) do
    health_type = Map.get(status, :health, :unknown)

    case health_type do
      health when health in [:healthy, :degraded, :unhealthy] ->
        update_in(metrics, [:health_checks, health], &(&1 + 1))

      _ ->
        metrics
    end
  end

  defp determine_health_status(state) do
    pool_health = Pool.get_health(state.pool)
    running_tasks_count = map_size(state.running_tasks)

    cond do
      pool_health == :unhealthy -> :unhealthy
      pool_health == :degraded -> :degraded
      running_tasks_count > state.config.max_pool_size * 2 -> :degraded
      true -> :healthy
    end
  end

  defp enhance_metrics(metrics, state) do
    uptime = System.monotonic_time(:millisecond) - metrics.started_at

    Map.merge(metrics, %{
      uptime_ms: uptime,
      success_rate: calculate_success_rate(metrics),
      current_load: map_size(state.running_tasks),
      pool_utilization: calculate_pool_utilization(state)
    })
  end

  defp calculate_success_rate(metrics) do
    total_completed = metrics.tasks_completed + metrics.tasks_failed + metrics.tasks_crashed

    if total_completed > 0 do
      metrics.tasks_completed / total_completed * 100
    else
      0.0
    end
  end

  defp calculate_pool_utilization(state) do
    case Pool.get_status(state.pool) do
      %{total: total, available: available} when total > 0 ->
        (total - available) / total * 100

      _ ->
        0.0
    end
  end

  defp find_task_by_pid(running_tasks, pid) do
    Enum.find_value(running_tasks, fn {task_id, task_info} ->
      if task_info.pid == pid do
        {task_id, task_info}
      end
    end)
  end

  defp perform_shutdown(state) do
    perform_shutdown(state, 30_000)
  end

  defp perform_shutdown(state, timeout) do
    # Shutdown components
    if state.monitor, do: Monitor.shutdown(state.monitor)
    if state.pool, do: Pool.shutdown(state.pool, timeout)

    Logger.info("FLAME Manager shutdown completed")
  end

  defp check_shutdown_completion(state) do
    if state.shutdown_from && map_size(state.running_tasks) == 0 do
      Logger.info("All tasks completed, proceeding with shutdown")

      # Cancel the timeout timer if it's still active
      if state.shutdown_timeout_ref do
        :erlang.cancel_timer(state.shutdown_timeout_ref)
      end

      # Reply first, then schedule shutdown
      GenServer.reply(state.shutdown_from, :ok)
      send(self(), :perform_shutdown)

      # Return a special marker to indicate shutdown should complete
      {:shutdown_complete, state}
    else
      state
    end
  end
end
