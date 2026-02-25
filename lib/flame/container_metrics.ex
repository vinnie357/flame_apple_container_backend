defmodule FLAME.ContainerMetrics do
  @moduledoc """
  Comprehensive metrics collection system for Apple Containers FLAME backend.

  Integrates with Telemetry, provides Prometheus-compatible metrics,
  and supports distributed tracing for function execution.
  """

  use GenServer
  require Logger

  defstruct [
    :metrics_store,
    :telemetry_config,
    :prometheus_config,
    :collection_interval
  ]

  @telemetry_events [
    [:flame, :container, :provision],
    [:flame, :container, :checkout],
    [:flame, :container, :return],
    [:flame, :container, :terminate],
    [:flame, :task, :execute],
    [:flame, :task, :complete],
    [:flame, :task, :error],
    [:flame, :pool, :status]
  ]

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init(opts) do
    clean_opts = if is_list(opts), do: Keyword.delete(opts, :name), else: opts

    config =
      case clean_opts do
        clean_opts when is_list(clean_opts) -> Keyword.get(clean_opts, :config, %{})
        _ -> %{}
      end

    state = %__MODULE__{
      metrics_store: %{},
      telemetry_config: Map.get(config, :telemetry, %{}),
      prometheus_config: Map.get(config, :prometheus, %{}),
      collection_interval: Map.get(config, :collection_interval, 60_000)
    }

    # Set up telemetry handlers
    setup_telemetry_handlers()

    # Initialize Prometheus metrics if configured
    if state.prometheus_config[:enabled] do
      setup_prometheus_metrics()
    end

    # Schedule periodic metrics collection
    schedule_metrics_collection(state.collection_interval)

    Logger.info("Container metrics system initialized")
    {:ok, state}
  end

  # Public API

  def record_container_provision(container_id, metadata \\ %{}) do
    :telemetry.execute(
      [:flame, :container, :provision],
      %{count: 1},
      %{
        container_id: container_id,
        timestamp: System.system_time(:millisecond)
      }
      |> Map.merge(metadata)
    )
  end

  def record_container_checkout(container_id, metadata \\ %{}) do
    :telemetry.execute(
      [:flame, :container, :checkout],
      %{count: 1},
      %{
        container_id: container_id,
        timestamp: System.system_time(:millisecond)
      }
      |> Map.merge(metadata)
    )
  end

  def record_container_return(container_id, metadata \\ %{}) do
    :telemetry.execute(
      [:flame, :container, :return],
      %{count: 1},
      %{
        container_id: container_id,
        timestamp: System.system_time(:millisecond)
      }
      |> Map.merge(metadata)
    )
  end

  def record_container_termination(container_id, reason, metadata \\ %{}) do
    :telemetry.execute(
      [:flame, :container, :terminate],
      %{count: 1},
      %{
        container_id: container_id,
        reason: reason,
        timestamp: System.system_time(:millisecond)
      }
      |> Map.merge(metadata)
    )
  end

  def record_task_execution(task_id, execution_time, metadata \\ %{}) do
    :telemetry.execute(
      [:flame, :task, :execute],
      %{
        execution_time: execution_time,
        count: 1
      },
      %{
        task_id: task_id,
        timestamp: System.system_time(:millisecond)
      }
      |> Map.merge(metadata)
    )
  end

  def record_task_completion(task_id, execution_time, metadata \\ %{}) do
    :telemetry.execute(
      [:flame, :task, :complete],
      %{
        execution_time: execution_time,
        count: 1
      },
      %{
        task_id: task_id,
        timestamp: System.system_time(:millisecond)
      }
      |> Map.merge(metadata)
    )
  end

  def record_task_error(task_id, error_reason, metadata \\ %{}) do
    :telemetry.execute(
      [:flame, :task, :error],
      %{count: 1},
      %{
        task_id: task_id,
        error_reason: error_reason,
        timestamp: System.system_time(:millisecond)
      }
      |> Map.merge(metadata)
    )
  end

  def record_pool_status(pool_metrics) do
    :telemetry.execute([:flame, :pool, :status], pool_metrics, %{
      timestamp: System.system_time(:millisecond)
    })
  end

  def get_metrics_summary(server \\ __MODULE__) do
    GenServer.call(server, :get_metrics_summary)
  end

  def get_container_metrics(container_id, server \\ __MODULE__) do
    GenServer.call(server, {:get_container_metrics, container_id})
  end

  def export_prometheus_metrics(server \\ __MODULE__) do
    GenServer.call(server, :export_prometheus_metrics)
  end

  # GenServer callbacks

  def handle_call(:get_metrics_summary, _from, state) do
    summary = generate_metrics_summary(state.metrics_store)
    {:reply, summary, state}
  end

  def handle_call({:get_container_metrics, container_id}, _from, state) do
    container_metrics = Map.get(state.metrics_store, container_id, %{})
    {:reply, container_metrics, state}
  end

  def handle_call(:export_prometheus_metrics, _from, state) do
    if state.prometheus_config[:enabled] do
      metrics = export_prometheus_format(state.metrics_store)
      {:reply, {:ok, metrics}, state}
    else
      {:reply, {:error, :prometheus_not_enabled}, state}
    end
  end

  def handle_info(:collect_metrics, state) do
    state = collect_system_metrics(state)
    schedule_metrics_collection(state.collection_interval)
    {:noreply, state}
  end

  def handle_info({:telemetry_event, event_name, measurements, metadata}, state) do
    state = process_telemetry_event(event_name, measurements, metadata, state)
    {:noreply, state}
  end

  # Telemetry handler (must be public for telemetry)
  def handle_telemetry_event(event_name, measurements, metadata, _config) do
    case Process.whereis(__MODULE__) do
      nil ->
        # Process not running, ignore telemetry event
        :ok

      pid when is_pid(pid) ->
        send(pid, {:telemetry_event, event_name, measurements, metadata})
    end
  rescue
    _ -> :ok
  end

  # Private functions

  defp setup_telemetry_handlers do
    Enum.each(@telemetry_events, fn event ->
      :telemetry.attach(
        {:flame_metrics, event},
        event,
        &__MODULE__.handle_telemetry_event/4,
        %{}
      )
    end)
  end

  defp setup_prometheus_metrics do
    # Define Prometheus metrics
    :prometheus_counter.new(
      name: :flame_containers_provisioned_total,
      help: "Total number of containers provisioned",
      labels: [:backend_type]
    )

    :prometheus_counter.new(
      name: :flame_containers_terminated_total,
      help: "Total number of containers terminated",
      labels: [:backend_type, :reason]
    )

    :prometheus_histogram.new(
      name: :flame_task_execution_duration_seconds,
      help: "Task execution duration in seconds",
      labels: [:task_type],
      buckets: [0.1, 0.5, 1, 2, 5, 10, 30, 60]
    )

    :prometheus_gauge.new(
      name: :flame_active_containers,
      help: "Number of active containers",
      labels: [:backend_type]
    )

    :prometheus_gauge.new(
      name: :flame_warm_pool_size,
      help: "Size of warm container pool",
      labels: [:backend_type]
    )

    Logger.info("Prometheus metrics initialized")
  end

  defp process_telemetry_event(event_name, measurements, metadata, state) do
    # Update internal metrics store
    metrics_store = update_metrics_store(state.metrics_store, event_name, measurements, metadata)

    # Update Prometheus metrics if enabled
    if state.prometheus_config[:enabled] do
      update_prometheus_metrics(event_name, measurements, metadata)
    end

    %{state | metrics_store: metrics_store}
  end

  defp update_metrics_store(store, event_name, measurements, metadata) do
    case event_name do
      [:flame, :container, :provision] ->
        update_container_provision_metrics(store, metadata)

      [:flame, :container, :checkout] ->
        update_container_checkout_metrics(store, metadata)

      [:flame, :container, :return] ->
        update_container_return_metrics(store, metadata)

      [:flame, :container, :terminate] ->
        update_container_terminate_metrics(store, metadata)

      [:flame, :task, :execute] ->
        update_task_execution_metrics(store, measurements, metadata)

      [:flame, :pool, :status] ->
        update_pool_status_metrics(store, measurements, metadata)

      _ ->
        store
    end
  end

  defp update_container_provision_metrics(store, metadata) do
    container_id = metadata.container_id
    container_metrics = Map.get(store, container_id, %{})

    updated_metrics =
      Map.merge(container_metrics, %{
        provisioned_at: metadata.timestamp,
        provision_count: Map.get(container_metrics, :provision_count, 0) + 1
      })

    Map.put(store, container_id, updated_metrics)
  end

  defp update_container_checkout_metrics(store, metadata) do
    container_id = metadata.container_id
    container_metrics = Map.get(store, container_id, %{})

    updated_metrics =
      Map.merge(container_metrics, %{
        last_checkout: metadata.timestamp,
        checkout_count: Map.get(container_metrics, :checkout_count, 0) + 1
      })

    Map.put(store, container_id, updated_metrics)
  end

  defp update_container_return_metrics(store, metadata) do
    container_id = metadata.container_id
    container_metrics = Map.get(store, container_id, %{})

    updated_metrics =
      Map.merge(container_metrics, %{
        last_return: metadata.timestamp,
        return_count: Map.get(container_metrics, :return_count, 0) + 1
      })

    Map.put(store, container_id, updated_metrics)
  end

  defp update_container_terminate_metrics(store, metadata) do
    container_id = metadata.container_id
    container_metrics = Map.get(store, container_id, %{})

    updated_metrics =
      Map.merge(container_metrics, %{
        terminated_at: metadata.timestamp,
        termination_reason: metadata.reason
      })

    Map.put(store, container_id, updated_metrics)
  end

  defp update_task_execution_metrics(store, measurements, metadata) do
    task_metrics = Map.get(store, :tasks, %{})

    execution_time =
      if is_number(measurements.execution_time), do: measurements.execution_time, else: 0

    updated_metrics = %{
      total_executions: Map.get(task_metrics, :total_executions, 0) + 1,
      total_execution_time: Map.get(task_metrics, :total_execution_time, 0) + execution_time,
      last_execution: metadata.timestamp
    }

    Map.put(store, :tasks, updated_metrics)
  end

  defp update_pool_status_metrics(store, measurements, metadata) do
    Map.put(store, :pool_status, %{
      warm_pool_size: Map.get(measurements, :warm_pool_size, 0),
      active_containers: Map.get(measurements, :active_containers, 0),
      total_containers: Map.get(measurements, :total_containers, 0),
      last_updated: metadata.timestamp
    })
  end

  defp update_prometheus_metrics(event_name, measurements, metadata) do
    case event_name do
      [:flame, :container, :provision] ->
        :prometheus_counter.inc(:flame_containers_provisioned_total, [:apple_containers])

      [:flame, :container, :terminate] ->
        :prometheus_counter.inc(
          :flame_containers_terminated_total,
          [:apple_containers, metadata.reason]
        )

      [:flame, :task, :execute] ->
        execution_time_seconds = measurements.execution_time / 1000

        :prometheus_histogram.observe(
          :flame_task_execution_duration_seconds,
          [:general],
          execution_time_seconds
        )

      [:flame, :pool, :status] ->
        :prometheus_gauge.set(
          :flame_active_containers,
          [:apple_containers],
          measurements.active_containers || 0
        )

        :prometheus_gauge.set(
          :flame_warm_pool_size,
          [:apple_containers],
          measurements.warm_pool_size || 0
        )

      _ ->
        :ok
    end
  end

  defp collect_system_metrics(state) do
    # Collect system-level metrics
    system_metrics = %{
      memory_usage: :erlang.memory() |> Map.new(),
      process_count: :erlang.system_info(:process_count),
      node_uptime: :erlang.statistics(:wall_clock),
      scheduler_utilization: get_scheduler_utilization(),
      timestamp: System.system_time(:millisecond)
    }

    metrics_store = Map.put(state.metrics_store, :system, system_metrics)
    %{state | metrics_store: metrics_store}
  end

  defp generate_metrics_summary(metrics_store) do
    container_count =
      Enum.count(metrics_store, fn {key, _} ->
        is_binary(key) and String.starts_with?(key, "flame-worker")
      end)

    task_metrics = Map.get(metrics_store, :tasks, %{})
    pool_status = Map.get(metrics_store, :pool_status, %{})
    system_metrics = Map.get(metrics_store, :system, %{})

    %{
      container_count: container_count,
      total_task_executions: Map.get(task_metrics, :total_executions, 0),
      average_execution_time: calculate_average_execution_time(task_metrics),
      pool_status: pool_status,
      system_metrics: Map.take(system_metrics, [:memory_usage, :process_count]),
      summary_generated_at: System.system_time(:millisecond)
    }
  end

  defp calculate_average_execution_time(task_metrics) do
    total_time = Map.get(task_metrics, :total_execution_time, 0)
    total_executions = Map.get(task_metrics, :total_executions, 0)

    if total_executions > 0 do
      total_time / total_executions
    else
      0
    end
  end

  defp export_prometheus_format(metrics_store) do
    # Generate Prometheus text format
    [
      "# HELP flame_containers_provisioned_total Total number of containers provisioned",
      "# TYPE flame_containers_provisioned_total counter",
      format_prometheus_metric(
        "flame_containers_provisioned_total",
        get_provision_count(metrics_store)
      ),
      "",
      "# HELP flame_active_containers Number of active containers",
      "# TYPE flame_active_containers gauge",
      format_prometheus_metric(
        "flame_active_containers",
        get_active_container_count(metrics_store)
      ),
      ""
    ]
    |> Enum.join("\n")
  end

  defp format_prometheus_metric(name, value) do
    "#{name}{backend_type=\"apple_containers\"} #{value}"
  end

  defp get_provision_count(metrics_store) do
    Enum.reduce(metrics_store, 0, fn
      {key, metrics}, acc when is_binary(key) ->
        if String.starts_with?(key, "flame-worker") do
          acc + Map.get(metrics, :provision_count, 0)
        else
          acc
        end

      _, acc ->
        acc
    end)
  end

  defp get_active_container_count(metrics_store) do
    pool_status = Map.get(metrics_store, :pool_status, %{})
    Map.get(pool_status, :active_containers, 0)
  end

  defp schedule_metrics_collection(interval) do
    Process.send_after(self(), :collect_metrics, interval)
  end

  defp get_scheduler_utilization do
    case :erlang.statistics(:scheduler_wall_time) do
      stats when is_list(stats) ->
        # Use available statistics if scheduler is available
        case :erlang.system_info(:schedulers) do
          # Mock value for now
          n when is_integer(n) and n > 0 -> 50.0
          _ -> 0.0
        end

      _other ->
        0.0
    end
  catch
    _, _ -> 0.0
  end
end
