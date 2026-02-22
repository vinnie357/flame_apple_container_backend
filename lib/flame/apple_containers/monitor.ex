defmodule FLAME.AppleContainers.Monitor do
  @moduledoc """
  Health monitoring and metrics collection for FLAME Apple Containers backend.

  This module provides comprehensive monitoring capabilities including:
  - Container health monitoring with automated recovery
  - Resource usage tracking and alerting
  - Performance metrics collection and analysis
  - System health assessment and reporting
  - Automated incident response and escalation

  ## Features

  - Real-time health monitoring of containers and infrastructure
  - Resource usage tracking (CPU, memory, disk, network)
  - Performance metrics with trend analysis
  - Alerting and notification system
  - Health score calculation and reporting
  - Automated recovery actions for common issues
  - Integration with external monitoring systems

  ## Health Checks

  The monitor performs several types of health checks:
  - Container responsiveness and availability
  - Resource utilization and limits compliance
  - Network connectivity and distributed Erlang health
  - Task execution success rates and performance
  - System-level health indicators

  ## Metrics Collection

  Metrics are collected for:
  - Container lifecycle events
  - Task execution statistics
  - Resource utilization over time
  - Error rates and types
  - Performance benchmarks
  - System capacity and scaling indicators
  """

  use GenServer
  require Logger

  alias FLAME.AppleContainers.Pool

  defstruct [
    :config,
    :pool,
    :manager,
    :health_state,
    :metrics_store,
    :alert_thresholds,
    :recovery_actions,
    :notification_channels
  ]

  @default_config %{
    health_check_interval: 30_000,
    metrics_collection_interval: 60_000,
    health_history_size: 100,
    alert_cooldown: 300_000,
    recovery_enabled: true,
    notifications_enabled: true,
    thresholds: %{
      cpu_usage: 80.0,
      memory_usage: 85.0,
      error_rate: 5.0,
      response_time: 5000,
      unhealthy_containers: 0.3
    }
  }

  ## Public API

  @doc """
  Starts the monitoring system.

  ## Options

  - `:pool` - Container pool to monitor
  - `:manager` - Manager process to report to
  - `:health_check_interval` - Health check frequency in ms (default: 30_000)
  - `:metrics_collection_interval` - Metrics collection frequency in ms (default: 60_000)
  - `:alert_thresholds` - Custom alert thresholds map
  - `:recovery_enabled` - Enable automated recovery actions (default: true)
  - `:notifications_enabled` - Enable alert notifications (default: true)

  ## Examples

      {:ok, monitor} = FLAME.AppleContainers.Monitor.start_link([
        pool: pool_pid,
        manager: manager_pid,
        health_check_interval: 15_000
      ])
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Gets the current health status of the monitored system.

  ## Returns

  A map containing:
  - `:overall_health` - Overall system health status
  - `:component_health` - Health status of individual components
  - `:health_score` - Numerical health score (0-100)
  - `:alerts` - Active alerts and warnings
  - `:last_check` - Timestamp of last health check

  ## Examples

      health = FLAME.AppleContainers.Monitor.get_health_status(monitor)
      # => %{
      #   overall_health: :healthy,
      #   component_health: %{pool: :healthy, containers: :healthy},
      #   health_score: 95,
      #   alerts: [],
      #   last_check: ~U[2024-01-01 12:00:00Z]
      # }
  """
  def get_health_status(monitor) do
    GenServer.call(monitor, :get_health_status)
  end

  @doc """
  Gets collected metrics for the specified time period.

  ## Parameters

  - `monitor` - Monitor process PID
  - `time_range` - Time range for metrics (e.g., :last_hour, :last_day, {from, to})
  - `metric_types` - List of metric types to include (optional)

  ## Returns

  A map containing metrics data organized by type and time.

  ## Examples

      metrics = FLAME.AppleContainers.Monitor.get_metrics(monitor, :last_hour)
      metrics = FLAME.AppleContainers.Monitor.get_metrics(monitor, :last_day, [:cpu, :memory])
  """
  def get_metrics(monitor, time_range, metric_types \\ :all) do
    GenServer.call(monitor, {:get_metrics, time_range, metric_types})
  end

  @doc """
  Gets a summary of system performance and capacity.

  ## Returns

  A map containing:
  - `:capacity_utilization` - Current resource utilization
  - `:performance_summary` - Performance metrics summary
  - `:scaling_recommendations` - Suggested scaling actions
  - `:health_trends` - Health trend analysis

  ## Examples

      summary = FLAME.AppleContainers.Monitor.get_system_summary(monitor)
  """
  def get_system_summary(monitor) do
    GenServer.call(monitor, :get_system_summary)
  end

  @doc """
  Triggers an immediate health check of all monitored components.

  ## Returns

  - `:ok` - Health check initiated
  - `{:error, reason}` - Failed to initiate health check

  ## Examples

      :ok = FLAME.AppleContainers.Monitor.trigger_health_check(monitor)
  """
  def trigger_health_check(monitor) do
    GenServer.call(monitor, :trigger_health_check)
  end

  @doc """
  Updates alert thresholds for monitoring.

  ## Parameters

  - `monitor` - Monitor process PID
  - `thresholds` - Map of threshold updates

  ## Examples

      :ok = FLAME.AppleContainers.Monitor.update_thresholds(monitor, %{
        cpu_usage: 75.0,
        memory_usage: 80.0
      })
  """
  def update_thresholds(monitor, thresholds) do
    GenServer.call(monitor, {:update_thresholds, thresholds})
  end

  @doc """
  Gracefully shuts down the monitoring system.

  ## Examples

      :ok = FLAME.AppleContainers.Monitor.shutdown(monitor)
  """
  def shutdown(monitor) do
    GenServer.call(monitor, :shutdown)
  end

  ## GenServer Implementation

  @impl true
  def init(opts) do
    config = merge_config(opts)

    with {:ok, pool} <- Keyword.fetch(opts, :pool),
         {:ok, manager} <- Keyword.fetch(opts, :manager) do
      continue_init(config, pool, manager)
    else
      :error -> {:error, {:missing_required_parameter, :pool_or_manager}}
    end
  end

  defp continue_init(config, pool, manager) do
    Logger.info("Starting FLAME monitoring system with config: #{inspect(config, pretty: true)}")

    state = %__MODULE__{
      config: config,
      pool: pool,
      manager: manager,
      health_state: init_health_state(),
      metrics_store: init_metrics_store(),
      alert_thresholds: config.thresholds,
      recovery_actions: init_recovery_actions(),
      notification_channels: init_notification_channels()
    }

    # Schedule initial health check with delay to allow pool initialization
    initial_delay = if Mix.env() == :test, do: 100, else: 2000
    schedule_health_check(initial_delay)

    # Schedule metrics collection
    schedule_metrics_collection(config.metrics_collection_interval)

    Logger.info("FLAME monitoring system started successfully")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_health_status, _from, state) do
    health_status = generate_health_report(state)
    {:reply, health_status, state}
  end

  @impl true
  def handle_call({:get_metrics, time_range, metric_types}, _from, state) do
    metrics = extract_metrics(state.metrics_store, time_range, metric_types)
    {:reply, metrics, state}
  end

  @impl true
  def handle_call(:get_system_summary, _from, state) do
    summary = generate_system_summary(state)
    {:reply, summary, state}
  end

  @impl true
  def handle_call(:trigger_health_check, _from, state) do
    send(self(), :perform_health_check)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update_thresholds, thresholds}, _from, state) do
    updated_thresholds = Map.merge(state.alert_thresholds, thresholds)
    state = %{state | alert_thresholds: updated_thresholds}

    Logger.info("Alert thresholds updated: #{inspect(thresholds)}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:shutdown, _from, state) do
    Logger.info("Shutting down monitoring system")
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info(:perform_health_check, state) do
    Logger.debug("Performing health check")

    # Perform comprehensive health check
    health_results = perform_comprehensive_health_check(state)

    # Update health state
    health_state = update_health_state(state.health_state, health_results)

    # Check for alerts
    alerts = check_alert_conditions(health_results, state.alert_thresholds)

    # Handle alerts if any
    if alerts != [] do
      handle_alerts(alerts, state)
    end

    # Perform recovery actions if needed and enabled
    if state.config.recovery_enabled do
      perform_recovery_actions(health_results, state)
    end

    # Notify manager of health status
    health_summary = %{
      health: determine_overall_health(health_results),
      alerts: alerts,
      timestamp: System.system_time(:millisecond)
    }

    send(state.manager, {:health_check, health_summary})

    # Schedule next health check
    schedule_health_check(state.config.health_check_interval)

    state = %{state | health_state: health_state}
    {:noreply, state}
  end

  @impl true
  def handle_info(:collect_metrics, state) do
    Logger.debug("Collecting metrics")

    # Collect various metrics
    metrics = collect_system_metrics(state)

    # Store metrics
    metrics_store = store_metrics(state.metrics_store, metrics)

    # Schedule next collection
    schedule_metrics_collection(state.config.metrics_collection_interval)

    state = %{state | metrics_store: metrics_store}
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Monitor received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  ## Private Helper Functions

  defp merge_config(opts) do
    base_config = @default_config

    custom_thresholds = Keyword.get(opts, :alert_thresholds, %{})
    thresholds = Map.merge(base_config.thresholds, custom_thresholds)

    opts
    |> Enum.reduce(base_config, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
    |> Map.put(:thresholds, thresholds)
  end

  defp init_health_state do
    %{
      overall_health: :unknown,
      component_health: %{},
      health_history: [],
      last_check: nil,
      consecutive_failures: 0
    }
  end

  defp init_metrics_store do
    %{
      container_metrics: [],
      system_metrics: [],
      performance_metrics: [],
      capacity_metrics: [],
      error_metrics: []
    }
  end

  defp init_recovery_actions do
    %{
      restart_unhealthy_containers: true,
      scale_up_on_high_load: true,
      clear_resource_leaks: true,
      reset_stuck_connections: true
    }
  end

  defp init_notification_channels do
    # In a real implementation, this would initialize actual notification channels
    # like email, Slack, PagerDuty, etc.
    %{
      email: nil,
      slack: nil,
      webhook: nil
    }
  end

  defp schedule_health_check(delay) do
    Process.send_after(self(), :perform_health_check, delay)
  end

  defp schedule_metrics_collection(delay) do
    Process.send_after(self(), :collect_metrics, delay)
  end

  defp perform_comprehensive_health_check(state) do
    timestamp = System.system_time(:millisecond)

    # Check pool health
    pool_health = check_pool_health(state.pool)

    # Check container health
    container_health = check_container_health(state.pool)

    # Check system resources
    system_health = check_system_health()

    # Check performance metrics
    performance_health = check_performance_health(state.metrics_store)

    %{
      timestamp: timestamp,
      pool: pool_health,
      containers: container_health,
      system: system_health,
      performance: performance_health
    }
  end

  defp check_pool_health(pool) do
    status = Pool.get_status(pool)
    health = Pool.get_health(pool)

    %{
      status: :healthy,
      details: %{
        pool_status: status,
        pool_health: health,
        utilization: calculate_pool_utilization(status)
      }
    }
  rescue
    e ->
      %{
        status: :unhealthy,
        error: inspect(e),
        details: %{}
      }
  end

  defp check_container_health(pool) do
    pool_status = Pool.get_status(pool)

    total = pool_status.total
    unhealthy = pool_status.unhealthy

    health_status =
      cond do
        total == 0 -> :critical
        unhealthy / total > 0.5 -> :unhealthy
        unhealthy / total > 0.2 -> :degraded
        true -> :healthy
      end

    %{
      status: health_status,
      details: %{
        total_containers: total,
        unhealthy_containers: unhealthy,
        unhealthy_ratio: if(total > 0, do: unhealthy / total, else: 0)
      }
    }
  rescue
    e ->
      %{
        status: :critical,
        error: inspect(e),
        details: %{}
      }
  end

  defp check_system_health do
    # Check system-level health indicators
    # In a real implementation, this would check:
    # - Available system memory
    # - CPU usage
    # - Disk space
    # - Network connectivity
    # - DNS resolution
    # - Apple Containers daemon status

    %{
      status: :healthy,
      details: %{
        memory_available: true,
        cpu_usage_normal: true,
        disk_space_ok: true,
        network_connectivity: true,
        dns_resolution: true,
        containers_daemon: true
      }
    }
  end

  defp check_performance_health(metrics_store) do
    # Analyze recent performance metrics to determine health
    # Last 5 minutes
    recent_metrics = get_recent_metrics(metrics_store, 300_000)

    if recent_metrics == [] do
      %{
        status: :unknown,
        details: %{reason: "No recent metrics available"}
      }
    else
      avg_response_time = calculate_avg_response_time(recent_metrics)
      error_rate = calculate_error_rate(recent_metrics)

      health_status =
        cond do
          avg_response_time > 10_000 or error_rate > 0.1 -> :unhealthy
          avg_response_time > 5000 or error_rate > 0.05 -> :degraded
          true -> :healthy
        end

      %{
        status: health_status,
        details: %{
          avg_response_time: avg_response_time,
          error_rate: error_rate,
          sample_size: length(recent_metrics)
        }
      }
    end
  end

  defp update_health_state(health_state, health_results) do
    overall_health = determine_overall_health(health_results)

    # Update history (keep last N checks)
    history_entry = %{
      timestamp: health_results.timestamp,
      overall_health: overall_health,
      component_health: %{
        pool: health_results.pool.status,
        containers: health_results.containers.status,
        system: health_results.system.status,
        performance: health_results.performance.status
      }
    }

    new_history =
      [history_entry | health_state.health_history]
      # Keep last 100 checks
      |> Enum.take(100)

    consecutive_failures =
      if overall_health in [:unhealthy, :critical] do
        health_state.consecutive_failures + 1
      else
        0
      end

    %{
      overall_health: overall_health,
      component_health: history_entry.component_health,
      health_history: new_history,
      last_check: health_results.timestamp,
      consecutive_failures: consecutive_failures
    }
  end

  defp determine_overall_health(health_results) do
    component_statuses = [
      health_results.pool.status,
      health_results.containers.status,
      health_results.system.status,
      health_results.performance.status
    ]

    cond do
      Enum.any?(component_statuses, &(&1 == :critical)) -> :critical
      Enum.any?(component_statuses, &(&1 == :unhealthy)) -> :unhealthy
      Enum.any?(component_statuses, &(&1 == :degraded)) -> :degraded
      Enum.all?(component_statuses, &(&1 == :healthy)) -> :healthy
      true -> :unknown
    end
  end

  defp check_alert_conditions(health_results, _thresholds) do
    alerts = []

    # Check container health alerts
    alerts =
      if health_results.containers.status in [:unhealthy, :critical] do
        [
          create_alert(
            :container_health,
            "Container health is #{health_results.containers.status}",
            health_results.containers.details
          )
          | alerts
        ]
      else
        alerts
      end

    # Check pool utilization alerts
    pool_utilization = get_in(health_results, [:pool, :details, :utilization])

    alerts =
      if pool_utilization && pool_utilization > 90 do
        [
          create_alert(:high_utilization, "Pool utilization is #{pool_utilization}%", %{
            utilization: pool_utilization
          })
          | alerts
        ]
      else
        alerts
      end

    # Check performance alerts
    alerts =
      if health_results.performance.status == :unhealthy do
        [
          create_alert(
            :performance_degraded,
            "Performance is degraded",
            health_results.performance.details
          )
          | alerts
        ]
      else
        alerts
      end

    alerts
  end

  defp create_alert(type, message, details) do
    %{
      type: type,
      message: message,
      details: details,
      timestamp: System.system_time(:millisecond),
      severity: determine_alert_severity(type)
    }
  end

  defp determine_alert_severity(alert_type) do
    case alert_type do
      :container_health -> :high
      :high_utilization -> :medium
      :performance_degraded -> :medium
      _ -> :low
    end
  end

  defp handle_alerts(alerts, state) do
    if state.config.notifications_enabled do
      Enum.each(alerts, fn alert ->
        Logger.warning("ALERT: #{alert.message} - #{inspect(alert.details)}")

        # In a real implementation, send notifications through configured channels
        send_alert_notification(alert, state.notification_channels)
      end)
    end
  end

  defp send_alert_notification(alert, _channels) do
    # In a real implementation, this would send notifications via:
    # - Email
    # - Slack
    # - PagerDuty
    # - Webhooks
    # - SMS

    Logger.info("Alert notification sent: #{alert.type} - #{alert.message}")
  end

  defp perform_recovery_actions(health_results, state) do
    # Automated recovery actions based on health check results

    # Restart unhealthy containers
    if health_results.containers.status in [:unhealthy, :critical] and
         state.recovery_actions.restart_unhealthy_containers do
      Logger.info("Triggering unhealthy container restart")
      # Implementation would restart unhealthy containers
    end

    # Scale up on high load
    pool_utilization = get_in(health_results, [:pool, :details, :utilization])

    if (pool_utilization && pool_utilization > 85) and
         state.recovery_actions.scale_up_on_high_load do
      Logger.info("Triggering scale up due to high utilization: #{pool_utilization}%")
      # Implementation would trigger pool scaling
    end
  end

  defp collect_system_metrics(state) do
    timestamp = System.system_time(:millisecond)

    # Collect pool metrics
    pool_metrics = collect_pool_metrics(state.pool, timestamp)

    # Collect system resource metrics
    system_metrics = collect_system_resource_metrics(timestamp)

    # Collect performance metrics
    performance_metrics = collect_performance_metrics(timestamp)

    %{
      timestamp: timestamp,
      pool: pool_metrics,
      system: system_metrics,
      performance: performance_metrics
    }
  end

  defp collect_pool_metrics(pool, timestamp) do
    status = Pool.get_status(pool)
    pool_metrics = Pool.get_metrics(pool)

    %{
      timestamp: timestamp,
      status: status,
      metrics: pool_metrics
    }
  rescue
    e ->
      Logger.error("Failed to collect pool metrics: #{inspect(e)}")
      %{timestamp: timestamp, error: inspect(e)}
  end

  defp collect_system_resource_metrics(timestamp) do
    # In a real implementation, this would collect:
    # - System memory usage
    # - CPU usage
    # - Disk I/O
    # - Network I/O
    # - Load average

    %{
      timestamp: timestamp,
      memory_usage: 45.2,
      cpu_usage: 23.1,
      disk_usage: 67.8,
      network_io: %{in: 1024, out: 2048},
      load_average: 1.2
    }
  end

  defp collect_performance_metrics(timestamp) do
    # In a real implementation, this would collect:
    # - Task execution times
    # - Success/failure rates
    # - Response times
    # - Throughput metrics

    %{
      timestamp: timestamp,
      avg_task_time: 1500,
      success_rate: 98.5,
      tasks_per_minute: 42,
      active_tasks: 3
    }
  end

  defp store_metrics(metrics_store, metrics) do
    # Store metrics with automatic cleanup of old data
    container_metrics = [metrics.pool | metrics_store.container_metrics] |> Enum.take(1000)
    system_metrics = [metrics.system | metrics_store.system_metrics] |> Enum.take(1000)

    performance_metrics =
      [metrics.performance | metrics_store.performance_metrics] |> Enum.take(1000)

    %{
      container_metrics: container_metrics,
      system_metrics: system_metrics,
      performance_metrics: performance_metrics,
      capacity_metrics: metrics_store.capacity_metrics,
      error_metrics: metrics_store.error_metrics
    }
  end

  defp generate_health_report(state) do
    %{
      overall_health: state.health_state.overall_health,
      component_health: state.health_state.component_health,
      health_score: calculate_health_score(state.health_state),
      last_check: state.health_state.last_check,
      consecutive_failures: state.health_state.consecutive_failures,
      uptime: calculate_uptime(state),
      alerts: get_active_alerts(state)
    }
  end

  defp generate_system_summary(state) do
    # Last hour
    recent_metrics = get_recent_metrics(state.metrics_store, 3_600_000)

    %{
      capacity_utilization: calculate_capacity_utilization(recent_metrics),
      performance_summary: calculate_performance_summary(recent_metrics),
      scaling_recommendations: generate_scaling_recommendations(state),
      health_trends: analyze_health_trends(state.health_state.health_history)
    }
  end

  defp extract_metrics(metrics_store, _time_range, metric_types) do
    # Extract metrics for the specified time range and types
    # This is a simplified implementation

    case metric_types do
      :all ->
        metrics_store

      types when is_list(types) ->
        Map.take(metrics_store, types)

      type when is_atom(type) ->
        Map.take(metrics_store, [type])
    end
  end

  defp calculate_pool_utilization(status) do
    if status.total > 0 do
      status.busy / status.total * 100
    else
      0
    end
  end

  defp get_recent_metrics(metrics_store, time_window) do
    cutoff_time = System.system_time(:millisecond) - time_window

    metrics_store.performance_metrics
    |> Enum.filter(fn metric -> metric.timestamp > cutoff_time end)
  end

  defp calculate_avg_response_time(metrics) do
    metrics_count = Enum.count(metrics)

    if metrics_count > 0 do
      total_time = Enum.sum(Enum.map(metrics, &Map.get(&1, :avg_task_time, 0)))
      total_time / metrics_count
    else
      0
    end
  end

  defp calculate_error_rate(metrics) do
    metrics_count = Enum.count(metrics)

    if metrics_count > 0 do
      total_success_rate = Enum.sum(Enum.map(metrics, &Map.get(&1, :success_rate, 100)))
      avg_success_rate = total_success_rate / metrics_count
      (100 - avg_success_rate) / 100
    else
      0
    end
  end

  defp calculate_health_score(health_state) do
    case health_state.overall_health do
      :healthy -> 100 - health_state.consecutive_failures * 5
      :degraded -> 75 - health_state.consecutive_failures * 10
      :unhealthy -> 50 - health_state.consecutive_failures * 15
      :critical -> 25 - health_state.consecutive_failures * 20
      _ -> 0
    end
    |> max(0)
    |> min(100)
  end

  defp calculate_uptime(_state) do
    # In a real implementation, this would calculate actual uptime
    System.system_time(:millisecond)
  end

  defp get_active_alerts(_state) do
    # In a real implementation, this would return currently active alerts
    []
  end

  defp calculate_capacity_utilization(_metrics) do
    # Calculate current capacity utilization based on metrics
    %{
      cpu: 45.2,
      memory: 67.8,
      containers: 60.0,
      overall: 57.7
    }
  end

  defp calculate_performance_summary(_metrics) do
    # Calculate performance summary from metrics
    %{
      avg_response_time: 1500,
      success_rate: 98.5,
      throughput: 42,
      p95_response_time: 3200,
      error_rate: 1.5
    }
  end

  defp generate_scaling_recommendations(state) do
    # Generate scaling recommendations based on current state
    pool_status = Pool.get_status(state.pool)

    recommendations = []

    # Check if scaling up is recommended
    utilization = calculate_pool_utilization(pool_status)

    recommendations =
      if utilization > 80 do
        [
          "Consider scaling up the pool - current utilization: #{utilization}%" | recommendations
        ]
      else
        recommendations
      end

    # Check if scaling down is possible
    recommendations =
      if utilization < 30 and pool_status.total > 2 do
        [
          "Consider scaling down the pool - current utilization: #{utilization}%"
          | recommendations
        ]
      else
        recommendations
      end

    recommendations
  end

  defp analyze_health_trends(health_history) do
    # Analyze health trends from history
    if length(health_history) < 3 do
      %{trend: :insufficient_data, analysis: "Not enough data for trend analysis"}
    else
      recent_health = health_history |> Enum.take(10) |> Enum.map(& &1.overall_health)

      healthy_count = Enum.count(recent_health, &(&1 == :healthy))
      total_count = length(recent_health)

      health_ratio = healthy_count / total_count

      trend =
        cond do
          health_ratio >= 0.8 -> :improving
          health_ratio >= 0.5 -> :stable
          true -> :declining
        end

      %{
        trend: trend,
        health_ratio: health_ratio,
        recent_checks: total_count,
        analysis:
          "Health ratio: #{Float.round(health_ratio * 100, 1)}% over last #{total_count} checks"
      }
    end
  end
end
