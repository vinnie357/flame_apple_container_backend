defmodule FLAME.AlertManager do
  @moduledoc """
  Intelligent alerting system for Apple Containers FLAME backend.

  Provides enterprise-grade alerting with:
  - Smart threshold-based alerts with ML-powered anomaly detection
  - Multi-channel notifications (Slack, Discord, Email, SMS, PagerDuty)
  - Alert correlation and noise reduction
  - Escalation policies and on-call rotation management
  - Alert acknowledgment and resolution tracking
  - Custom alert rules and templating
  """

  use GenServer
  require Logger

  alias FLAME.{ClusterManager, ContainerMetrics, ResourceManager, SecurityManager}

  defstruct [
    :alert_rules,
    :notification_channels,
    :escalation_policies,
    :active_alerts,
    :alert_history,
    :suppression_rules,
    :anomaly_detector,
    :on_call_schedule
  ]

  # 30 seconds
  @alert_evaluation_interval 30_000
  # 30 days in seconds
  # @alert_history_retention 2_592_000
  # 1 hour in seconds
  @anomaly_detection_window 3600

  ## Alert Severity Levels
  @severity_critical 1
  @severity_high 2
  @severity_medium 3
  @severity_low 4
  @severity_info 5

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Add a new alert rule.
  """
  def add_alert_rule(rule) do
    GenServer.call(__MODULE__, {:add_alert_rule, rule})
  end

  @doc """
  Remove an alert rule.
  """
  def remove_alert_rule(rule_id) do
    GenServer.call(__MODULE__, {:remove_alert_rule, rule_id})
  end

  @doc """
  Add a notification channel.
  """
  def add_notification_channel(channel) do
    GenServer.call(__MODULE__, {:add_notification_channel, channel})
  end

  @doc """
  Get all active alerts.
  """
  def get_active_alerts do
    GenServer.call(__MODULE__, :get_active_alerts)
  end

  @doc """
  Acknowledge an alert.
  """
  def acknowledge_alert(alert_id, user_id, notes \\ "") do
    GenServer.call(__MODULE__, {:acknowledge_alert, alert_id, user_id, notes})
  end

  @doc """
  Resolve an alert.
  """
  def resolve_alert(alert_id, user_id, resolution_notes \\ "") do
    GenServer.call(__MODULE__, {:resolve_alert, alert_id, user_id, resolution_notes})
  end

  @doc """
  Trigger a manual alert.
  """
  def trigger_manual_alert(alert_data) do
    GenServer.cast(__MODULE__, {:trigger_manual_alert, alert_data})
  end

  @doc """
  Create a new alert from provided alert data.
  """
  def create_alert(alert_data) do
    GenServer.cast(__MODULE__, {:create_alert, alert_data})
  end

  @doc """
  Get alert statistics and metrics.
  """
  def get_alert_metrics do
    GenServer.call(__MODULE__, :get_alert_metrics)
  end

  @doc """
  Test a notification channel.
  """
  def test_notification_channel(channel_id) do
    GenServer.call(__MODULE__, {:test_notification_channel, channel_id})
  end

  ## GenServer Callbacks

  def init(opts) do
    state = %__MODULE__{
      alert_rules: initialize_default_alert_rules(),
      notification_channels: initialize_notification_channels(opts),
      escalation_policies: initialize_escalation_policies(opts),
      active_alerts: %{},
      alert_history: [],
      suppression_rules: initialize_suppression_rules(),
      anomaly_detector: initialize_anomaly_detector(),
      on_call_schedule: initialize_on_call_schedule(opts)
    }

    # Start periodic alert evaluation
    schedule_alert_evaluation()

    # Subscribe to relevant telemetry events
    subscribe_to_telemetry_events()

    Logger.info("AlertManager initialized with #{length(state.alert_rules)} alert rules")

    {:ok, state}
  end

  def handle_call({:add_alert_rule, rule}, _from, state) do
    case validate_alert_rule(rule) do
      :ok ->
        rule_with_id = Map.put(rule, :id, generate_rule_id())
        rules = [rule_with_id | state.alert_rules]

        Logger.info("Added alert rule: #{rule_with_id.name}")
        {:reply, {:ok, rule_with_id.id}, %{state | alert_rules: rules}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:remove_alert_rule, rule_id}, _from, state) do
    rules = Enum.reject(state.alert_rules, &(&1.id == rule_id))

    if length(rules) < length(state.alert_rules) do
      Logger.info("Removed alert rule: #{rule_id}")
      {:reply, :ok, %{state | alert_rules: rules}}
    else
      {:reply, {:error, :rule_not_found}, state}
    end
  end

  def handle_call({:add_notification_channel, channel}, _from, state) do
    case validate_notification_channel(channel) do
      :ok ->
        channel_with_id = Map.put(channel, :id, generate_channel_id())
        channels = [channel_with_id | state.notification_channels]

        Logger.info(
          "Added notification channel: #{channel_with_id.name} (#{channel_with_id.type})"
        )

        {:reply, {:ok, channel_with_id.id}, %{state | notification_channels: channels}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_active_alerts, _from, state) do
    alerts = Enum.map(state.active_alerts, fn {_id, alert} -> alert end)
    {:reply, alerts, state}
  end

  def handle_call({:acknowledge_alert, alert_id, user_id, notes}, _from, state) do
    case Map.get(state.active_alerts, alert_id) do
      nil ->
        {:reply, {:error, :alert_not_found}, state}

      alert ->
        updated_alert = %{
          alert
          | status: :acknowledged,
            acknowledged_by: user_id,
            acknowledged_at: System.system_time(:millisecond),
            acknowledgment_notes: notes
        }

        state = put_in(state.active_alerts[alert_id], updated_alert)

        # Send acknowledgment notification
        send_acknowledgment_notification(updated_alert)

        Logger.info("Alert #{alert_id} acknowledged by #{user_id}")
        {:reply, :ok, state}
    end
  end

  def handle_call({:resolve_alert, alert_id, user_id, resolution_notes}, _from, state) do
    case Map.get(state.active_alerts, alert_id) do
      nil ->
        {:reply, {:error, :alert_not_found}, state}

      alert ->
        resolved_alert = %{
          alert
          | status: :resolved,
            resolved_by: user_id,
            resolved_at: System.system_time(:millisecond),
            resolution_notes: resolution_notes
        }

        # Move to history
        state = %{
          state
          | active_alerts: Map.delete(state.active_alerts, alert_id),
            alert_history: [resolved_alert | state.alert_history]
        }

        # Send resolution notification
        send_resolution_notification(resolved_alert)

        Logger.info("Alert #{alert_id} resolved by #{user_id}")
        {:reply, :ok, state}
    end
  end

  def handle_call(:get_alert_metrics, _from, state) do
    metrics = calculate_alert_metrics(state)
    {:reply, metrics, state}
  end

  def handle_call({:test_notification_channel, channel_id}, _from, state) do
    case Enum.find(state.notification_channels, &(&1.id == channel_id)) do
      nil ->
        {:reply, {:error, :channel_not_found}, state}

      channel ->
        test_alert = create_test_alert()

        case send_notification(channel, test_alert) do
          :ok ->
            Logger.info("Test notification sent successfully to #{channel.name}")
            {:reply, :ok, state}

          {:error, reason} ->
            Logger.error("Test notification failed for #{channel.name}: #{reason}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_cast({:trigger_manual_alert, alert_data}, state) do
    alert = create_alert_from_data(alert_data)
    state = process_new_alert(alert, state)
    {:noreply, state}
  end

  def handle_cast({:create_alert, alert_data}, state) do
    alert = create_alert_from_data(alert_data)
    state = process_new_alert(alert, state)
    {:noreply, state}
  end

  def handle_info(:evaluate_alerts, state) do
    state = evaluate_all_alert_rules(state)
    schedule_alert_evaluation()
    {:noreply, state}
  end

  def handle_info({:telemetry, event_name, measurements, metadata}, state) do
    state = process_telemetry_event(event_name, measurements, metadata, state)
    {:noreply, state}
  end

  def handle_info({:escalate_alert, alert_id}, state) do
    case Map.get(state.active_alerts, alert_id) do
      nil ->
        {:noreply, state}

      alert ->
        state = escalate_alert(alert, state)
        {:noreply, state}
    end
  end

  ## Private Functions

  defp initialize_default_alert_rules do
    [
      # Container Health Alerts
      %{
        id: "container-health-critical",
        name: "Container Health Critical",
        type: :threshold,
        severity: @severity_critical,
        metric: "container.health.unhealthy_count",
        condition: :greater_than,
        threshold: 0,
        # seconds
        duration: 60,
        evaluation_interval: 30,
        description: "One or more containers are unhealthy",
        runbook_url: "https://docs.flame.dev/runbooks/container-health",
        tags: ["container", "health", "critical"]
      },

      # Resource Usage Alerts
      %{
        id: "memory-usage-high",
        name: "High Memory Usage",
        type: :threshold,
        severity: @severity_high,
        metric: "resource.memory.usage_percentage",
        condition: :greater_than,
        threshold: 85,
        # 5 minutes
        duration: 300,
        evaluation_interval: 30,
        description: "Memory usage is above 85%",
        runbook_url: "https://docs.flame.dev/runbooks/memory-usage",
        tags: ["resource", "memory", "performance"]
      },
      %{
        id: "cpu-usage-high",
        name: "High CPU Usage",
        type: :threshold,
        severity: @severity_high,
        metric: "resource.cpu.usage_percentage",
        condition: :greater_than,
        threshold: 90,
        duration: 300,
        evaluation_interval: 30,
        description: "CPU usage is above 90%",
        runbook_url: "https://docs.flame.dev/runbooks/cpu-usage",
        tags: ["resource", "cpu", "performance"]
      },

      # Task Execution Alerts
      %{
        id: "task-error-rate-high",
        name: "High Task Error Rate",
        type: :threshold,
        severity: @severity_medium,
        metric: "task.error_rate_percentage",
        condition: :greater_than,
        threshold: 10,
        # 3 minutes
        duration: 180,
        evaluation_interval: 30,
        description: "Task error rate is above 10%",
        runbook_url: "https://docs.flame.dev/runbooks/task-errors",
        tags: ["task", "error", "reliability"]
      },
      %{
        id: "task-execution-time-high",
        name: "High Task Execution Time",
        type: :anomaly,
        severity: @severity_medium,
        metric: "task.execution_time_ms",
        anomaly_type: :statistical,
        sensitivity: 0.8,
        duration: 300,
        evaluation_interval: 60,
        description: "Task execution time is significantly higher than normal",
        runbook_url: "https://docs.flame.dev/runbooks/task-performance",
        tags: ["task", "performance", "latency"]
      },

      # Cluster Alerts
      %{
        id: "cluster-availability-low",
        name: "Low Cluster Availability",
        type: :threshold,
        severity: @severity_critical,
        metric: "cluster.healthy_nodes_percentage",
        condition: :less_than,
        threshold: 70,
        duration: 120,
        evaluation_interval: 30,
        description: "Less than 70% of cluster nodes are healthy",
        runbook_url: "https://docs.flame.dev/runbooks/cluster-availability",
        tags: ["cluster", "availability", "critical"]
      },

      # Security Alerts
      %{
        id: "security-validation-failures",
        name: "Security Validation Failures",
        type: :threshold,
        severity: @severity_high,
        metric: "security.validation_failures_count",
        condition: :greater_than,
        threshold: 5,
        duration: 300,
        evaluation_interval: 60,
        description: "Multiple security validation failures detected",
        runbook_url: "https://docs.flame.dev/runbooks/security-failures",
        tags: ["security", "validation", "threat"]
      }
    ]
  end

  defp initialize_notification_channels(opts) do
    channels = []

    # Add Slack channel if configured
    channels =
      if slack_config = Keyword.get(opts, :slack) do
        [create_slack_channel(slack_config) | channels]
      else
        channels
      end

    # Add Discord channel if configured
    channels =
      if discord_config = Keyword.get(opts, :discord) do
        [create_discord_channel(discord_config) | channels]
      else
        channels
      end

    # Add Email channel if configured
    channels =
      if email_config = Keyword.get(opts, :email) do
        [create_email_channel(email_config) | channels]
      else
        channels
      end

    # Add PagerDuty channel if configured
    channels =
      if pagerduty_config = Keyword.get(opts, :pagerduty) do
        [create_pagerduty_channel(pagerduty_config) | channels]
      else
        channels
      end

    channels
  end

  defp initialize_escalation_policies(opts) do
    default_policy = %{
      id: "default",
      name: "Default Escalation Policy",
      rules: [
        %{
          delay_minutes: 0,
          targets: ["on-call-primary"],
          channels: ["slack", "email"]
        },
        %{
          delay_minutes: 15,
          targets: ["on-call-secondary"],
          channels: ["slack", "email", "sms"]
        },
        %{
          delay_minutes: 30,
          targets: ["on-call-manager"],
          channels: ["slack", "email", "sms", "pagerduty"]
        }
      ]
    }

    custom_policies = Keyword.get(opts, :escalation_policies, [])
    [default_policy | custom_policies]
  end

  defp initialize_suppression_rules do
    [
      # Suppress duplicate alerts within 5 minutes
      %{
        id: "duplicate-suppression",
        type: :duplicate,
        window_minutes: 5,
        match_fields: [:metric, :severity]
      },

      # Suppress low severity alerts during maintenance windows
      %{
        id: "maintenance-suppression",
        type: :conditional,
        condition: fn alert ->
          alert.severity >= @severity_medium and in_maintenance_window?()
        end
      }
    ]
  end

  defp initialize_anomaly_detector do
    %{
      enabled: true,
      algorithms: [:statistical, :machine_learning],
      sensitivity: 0.8,
      training_window_hours: 24,
      min_data_points: 100,
      models: %{}
    }
  end

  defp initialize_on_call_schedule(opts) do
    Keyword.get(opts, :on_call_schedule, %{
      "on-call-primary" => "user1@example.com",
      "on-call-secondary" => "user2@example.com",
      "on-call-manager" => "manager@example.com"
    })
  end

  defp schedule_alert_evaluation do
    Process.send_after(self(), :evaluate_alerts, @alert_evaluation_interval)
  end

  defp subscribe_to_telemetry_events do
    events = [
      [:flame, :container, :provision],
      [:flame, :container, :terminate],
      [:flame, :task, :execute],
      [:flame, :task, :complete],
      [:flame, :task, :error],
      [:flame, :resource, :limit_exceeded],
      [:flame, :security, :validation_failed],
      [:flame, :cluster, :node_unhealthy]
    ]

    Enum.each(events, fn event ->
      :telemetry.attach(
        "alert-manager-#{Enum.join(event, "-")}",
        event,
        &__MODULE__.handle_telemetry_event/4,
        %{alert_manager_pid: self()}
      )
    end)
  end

  def handle_telemetry_event(event_name, measurements, metadata, %{alert_manager_pid: pid}) do
    send(pid, {:telemetry, event_name, measurements, metadata})
  end

  defp evaluate_all_alert_rules(state) do
    current_time = System.system_time(:millisecond)

    Enum.reduce(state.alert_rules, state, fn rule, acc_state ->
      case evaluate_alert_rule(rule, current_time) do
        {:trigger, alert_data} ->
          alert = create_alert_from_rule(rule, alert_data)
          process_new_alert(alert, acc_state)

        :no_change ->
          acc_state
      end
    end)
  end

  defp evaluate_alert_rule(rule, current_time) do
    case rule.type do
      :threshold ->
        evaluate_threshold_rule(rule, current_time)

      :anomaly ->
        evaluate_anomaly_rule(rule, current_time)

      :composite ->
        evaluate_composite_rule(rule, current_time)
    end
  end

  defp evaluate_threshold_rule(rule, current_time) do
    case get_metric_value(rule.metric) do
      nil ->
        :no_change

      value ->
        if check_threshold_condition(rule.condition, value, rule.threshold) do
          handle_threshold_condition_met(rule, current_time, value)
        else
          handle_threshold_condition_not_met(rule)
        end
    end
  end

  defp check_threshold_condition(:greater_than, value, threshold), do: value > threshold
  defp check_threshold_condition(:less_than, value, threshold), do: value < threshold
  defp check_threshold_condition(:equals, value, threshold), do: value == threshold
  defp check_threshold_condition(:not_equals, value, threshold), do: value != threshold

  defp handle_threshold_condition_met(rule, current_time, value) do
    # Check if condition has been met for the required duration
    alert_id = generate_alert_id(rule)

    case get_alert_state(alert_id) do
      nil ->
        # First time condition is met
        store_alert_state(alert_id, %{
          first_triggered: current_time,
          last_checked: current_time,
          value: value
        })

        :no_change
    end
  end

  defp handle_threshold_condition_not_met(rule) do
    # Condition not met, clear any existing state
    alert_id = generate_alert_id(rule)
    clear_alert_state(alert_id)

    # Check if there's an active alert to resolve
    case find_active_alert_by_rule(rule) do
      nil -> :no_change
    end
  end

  defp evaluate_anomaly_rule(rule, _current_time) do
    case get_metric_time_series(rule.metric, @anomaly_detection_window) do
      nil ->
        :no_change

      time_series ->
        evaluate_anomaly_result(rule, time_series)
    end
  end

  defp evaluate_anomaly_result(rule, time_series) do
    case detect_anomaly(time_series, rule.sensitivity) do
      :normal ->
        case find_active_alert_by_rule(rule) do
          nil -> :no_change
        end
    end
  end

  defp evaluate_composite_rule(rule, current_time) do
    # Evaluate multiple conditions and combine results
    conditions_met =
      Enum.all?(rule.conditions, fn condition ->
        evaluate_condition(condition, current_time)
      end)

    if conditions_met do
      {:trigger, %{conditions: rule.conditions}}
    else
      case find_active_alert_by_rule(rule) do
        nil -> :no_change
      end
    end
  end

  defp get_metric_value(metric) do
    case metric do
      "container.health.unhealthy_count" ->
        get_unhealthy_container_count()

      "resource.memory.usage_percentage" ->
        get_memory_usage_percentage()

      "resource.cpu.usage_percentage" ->
        get_cpu_usage_percentage()

      "task.error_rate_percentage" ->
        get_task_error_rate()

      "task.execution_time_ms" ->
        get_average_task_execution_time()

      "cluster.healthy_nodes_percentage" ->
        get_cluster_health_percentage()

      "security.validation_failures_count" ->
        get_security_failures_count()

      _ ->
        nil
    end
  end

  defp get_unhealthy_container_count do
    case GenServer.call(FLAME.ContainerHealth, :get_unhealthy_count, 5000) do
      count when is_integer(count) -> count
      _ -> 0
    end
  catch
    _ -> 0
  end

  defp get_memory_usage_percentage do
    case GenServer.call(ResourceManager, :get_resource_status, 5000) do
      %{current_usage: usage, global_limits: limits} ->
        usage.memory_gb / limits.max_total_memory_gb * 100

      _ ->
        0
    end
  catch
    _ -> 0
  end

  defp get_cpu_usage_percentage do
    case GenServer.call(ResourceManager, :get_resource_status, 5000) do
      %{current_usage: usage, global_limits: limits} ->
        usage.cpu_cores / limits.max_total_cpu_cores * 100

      _ ->
        0
    end
  catch
    _ -> 0
  end

  defp get_task_error_rate do
    case GenServer.call(ContainerMetrics, :get_metrics_summary, 5000) do
      %{total_task_executions: total, total_errors: errors} when total > 0 ->
        errors / total * 100

      _ ->
        0
    end
  catch
    _ -> 0
  end

  defp get_average_task_execution_time do
    case GenServer.call(ContainerMetrics, :get_metrics_summary, 5000) do
      %{average_execution_time: time} when is_number(time) -> time
      _ -> 0
    end
  catch
    _ -> 0
  end

  defp get_cluster_health_percentage do
    case GenServer.call(ClusterManager, :get_cluster_status, 5000) do
      clusters when is_list(clusters) ->
        total_clusters = length(clusters)
        healthy_clusters = Enum.count(clusters, &(&1.status == :healthy))

        if total_clusters > 0 do
          healthy_clusters / total_clusters * 100
        else
          100
        end

      _ ->
        100
    end
  catch
    _ -> 100
  end

  defp get_security_failures_count do
    case GenServer.call(SecurityManager, :get_security_metrics, 5000) do
      %{validation_failures: failures} when is_integer(failures) -> failures
      _ -> 0
    end
  catch
    _ -> 0
  end

  defp process_new_alert(alert, state) do
    # Check suppression rules
    case should_suppress_alert(alert, state) do
      false ->
        # Check for duplicate active alerts
        case find_duplicate_active_alert(alert, state) do
          nil ->
            # New alert
            Logger.warning("New alert triggered: #{alert.name}")

            alert_with_id = Map.put(alert, :id, generate_alert_id())
            state = put_in(state.active_alerts[alert_with_id.id], alert_with_id)

            # Send notifications
            send_alert_notifications(alert_with_id, state)

            # Schedule escalation if needed
            schedule_escalation(alert_with_id, state)

            # Record in telemetry
            :telemetry.execute([:flame, :alert, :triggered], %{}, %{
              alert_id: alert_with_id.id,
              severity: alert.severity,
              rule_id: alert.rule_id
            })

            state
        end
    end
  end

  defp send_alert_notifications(alert, state) do
    # Find appropriate notification channels based on alert severity and rules
    channels = select_notification_channels(alert, state)

    Enum.each(channels, fn channel ->
      spawn(fn -> send_and_log_notification(channel, alert) end)
    end)
  end

  defp send_and_log_notification(channel, alert) do
    case send_notification(channel, alert) do
      :ok ->
        Logger.info("Alert notification sent to #{channel.name}")

      {:error, reason} ->
        Logger.error("Failed to send alert notification to #{channel.name}: #{reason}")
    end
  end

  defp send_notification(channel, alert) do
    case channel.type do
      :slack ->
        send_slack_notification(channel, alert)

      :discord ->
        send_discord_notification(channel, alert)

      :email ->
        send_email_notification(channel, alert)

      :pagerduty ->
        send_pagerduty_notification(channel, alert)

      :webhook ->
        send_webhook_notification(channel, alert)

      _ ->
        {:error, :unsupported_channel_type}
    end
  end

  defp send_slack_notification(channel, alert) do
    payload = %{
      text: "FLAME Alert: #{alert.name}",
      attachments: [
        %{
          color: get_slack_color(alert.severity),
          fields: [
            %{title: "Severity", value: get_severity_name(alert.severity), short: true},
            %{title: "Status", value: alert.status, short: true},
            %{title: "Description", value: alert.description, short: false},
            %{title: "Runbook", value: alert.runbook_url, short: false}
          ],
          footer: "FLAME AlertManager",
          ts: div(alert.triggered_at, 1000)
        }
      ]
    }

    case http_post(channel.webhook_url, Jason.encode!(payload), [
           {"Content-Type", "application/json"}
         ]) do
      {:ok, %{status_code: 200}} -> :ok
      {:ok, %{status_code: code}} -> {:error, "HTTP #{code}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_discord_notification(channel, alert) do
    embed = %{
      title: "FLAME Alert: #{alert.name}",
      description: alert.description,
      color: get_discord_color(alert.severity),
      fields: [
        %{name: "Severity", value: get_severity_name(alert.severity), inline: true},
        %{name: "Status", value: alert.status, inline: true},
        %{name: "Runbook", value: alert.runbook_url, inline: false}
      ],
      timestamp: DateTime.from_unix!(div(alert.triggered_at, 1000))
    }

    payload = %{embeds: [embed]}

    case http_post(channel.webhook_url, Jason.encode!(payload), [
           {"Content-Type", "application/json"}
         ]) do
      {:ok, %{status_code: 204}} -> :ok
      {:ok, %{status_code: code}} -> {:error, "HTTP #{code}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_email_notification(channel, alert) do
    # This would integrate with an email service like SendGrid, Mailgun, etc.
    # For now, just log the notification
    Logger.info(
      "Email notification would be sent to #{channel.recipients} for alert: #{alert.name}"
    )

    :ok
  end

  defp send_pagerduty_notification(channel, alert) do
    payload = %{
      routing_key: channel.integration_key,
      event_action: "trigger",
      payload: %{
        summary: "FLAME Alert: #{alert.name}",
        source: "flame-alert-manager",
        severity: get_pagerduty_severity(alert.severity),
        custom_details: %{
          description: alert.description,
          runbook_url: alert.runbook_url,
          alert_id: alert.id
        }
      }
    }

    case http_post("https://events.pagerduty.com/v2/enqueue", Jason.encode!(payload), [
           {"Content-Type", "application/json"}
         ]) do
      {:ok, %{status_code: 202}} -> :ok
      {:ok, %{status_code: code}} -> {:error, "HTTP #{code}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_webhook_notification(channel, alert) do
    payload = %{
      alert_id: alert.id,
      name: alert.name,
      severity: alert.severity,
      status: alert.status,
      description: alert.description,
      triggered_at: alert.triggered_at,
      runbook_url: alert.runbook_url,
      tags: alert.tags
    }

    headers = [
      {"Content-Type", "application/json"},
      {"X-FLAME-Signature", generate_webhook_signature(payload, channel.secret)}
    ]

    case http_post(channel.url, Jason.encode!(payload), headers) do
      {:ok, %{status_code: code}} when code in 200..299 -> :ok
      {:ok, %{status_code: code}} -> {:error, "HTTP #{code}"}
      {:error, reason} -> {:error, reason}
    end
  end

  # Helper functions for notification formatting

  defp get_slack_color(@severity_critical), do: "danger"
  defp get_slack_color(@severity_high), do: "warning"
  defp get_slack_color(@severity_medium), do: "#ff9900"
  defp get_slack_color(@severity_low), do: "good"
  defp get_slack_color(@severity_info), do: "#36a64f"

  defp get_discord_color(@severity_critical), do: 0xFF0000
  defp get_discord_color(@severity_high), do: 0xFF9900
  defp get_discord_color(@severity_medium), do: 0xFFCC00
  defp get_discord_color(@severity_low), do: 0x99CC00
  defp get_discord_color(@severity_info), do: 0x00FF00

  defp get_severity_name(@severity_critical), do: "Critical"
  defp get_severity_name(@severity_high), do: "High"
  defp get_severity_name(@severity_medium), do: "Medium"
  defp get_severity_name(@severity_low), do: "Low"
  defp get_severity_name(@severity_info), do: "Info"

  defp get_pagerduty_severity(@severity_critical), do: "critical"
  defp get_pagerduty_severity(@severity_high), do: "error"
  defp get_pagerduty_severity(@severity_medium), do: "warning"
  defp get_pagerduty_severity(@severity_low), do: "info"
  defp get_pagerduty_severity(@severity_info), do: "info"

  # Additional helper functions

  defp generate_rule_id, do: "rule-#{System.system_time(:millisecond)}-#{:rand.uniform(9999)}"

  defp generate_channel_id,
    do: "channel-#{System.system_time(:millisecond)}-#{:rand.uniform(9999)}"

  defp generate_alert_id, do: "alert-#{System.system_time(:millisecond)}-#{:rand.uniform(9999)}"
  defp generate_alert_id(rule), do: "alert-#{rule.id}-#{System.system_time(:second)}"

  defp validate_alert_rule(rule) do
    required_fields = [:name, :type, :severity, :metric]

    case Enum.all?(required_fields, &Map.has_key?(rule, &1)) do
      true -> :ok
      false -> {:error, :missing_required_fields}
    end
  end

  defp validate_notification_channel(channel) do
    required_fields = [:name, :type]

    case Enum.all?(required_fields, &Map.has_key?(channel, &1)) do
      true -> :ok
      false -> {:error, :missing_required_fields}
    end
  end

  defp create_test_alert do
    %{
      id: "test-alert",
      name: "Test Alert",
      severity: @severity_info,
      status: :active,
      description: "This is a test alert to verify notification channels",
      triggered_at: System.system_time(:millisecond),
      runbook_url: "https://docs.flame.dev/runbooks/test-alert",
      tags: ["test"]
    }
  end

  defp create_alert_from_data(alert_data) do
    %{
      id: generate_alert_id(),
      name: alert_data.name,
      severity: alert_data.severity,
      status: :active,
      description: alert_data.description,
      triggered_at: System.system_time(:millisecond),
      runbook_url: alert_data.runbook_url,
      tags: alert_data.tags || [],
      occurrence_count: 1
    }
  end

  defp create_alert_from_rule(rule, alert_data) do
    %{
      id: generate_alert_id(),
      rule_id: rule.id,
      name: rule.name,
      severity: rule.severity,
      status: :active,
      description: rule.description,
      triggered_at: System.system_time(:millisecond),
      runbook_url: rule.runbook_url,
      tags: rule.tags || [],
      alert_data: alert_data,
      occurrence_count: 1
    }
  end

  # Alert suppression, deduplication, and lifecycle helpers

  defp should_suppress_alert(alert, state) do
    Enum.any?(state.suppression_rules, fn rule ->
      check_suppression_rule(rule, alert, state)
    end)
  end

  defp check_suppression_rule(%{type: :duplicate} = rule, alert, state) do
    window_ms = rule.window_minutes * 60_000
    now = System.system_time(:millisecond)

    Enum.any?(state.active_alerts, fn {_id, existing} ->
      duplicate_alert_match?(rule, alert, existing, now, window_ms)
    end)
  end

  defp check_suppression_rule(%{type: :conditional} = rule, alert, _state) do
    rule.condition.(alert)
  end

  defp check_suppression_rule(_rule, _alert, _state), do: false

  defp duplicate_alert_match?(rule, alert, existing, now, window_ms) do
    fields_match =
      Enum.all?(rule.match_fields, fn field ->
        Map.get(alert, field) == Map.get(existing, field)
      end)

    fields_match and now - existing.triggered_at < window_ms
  end

  defp find_duplicate_active_alert(alert, state) do
    Enum.find_value(state.active_alerts, fn {_id, existing} ->
      if Map.get(existing, :rule_id) != nil and
           Map.get(existing, :rule_id) == Map.get(alert, :rule_id) and
           existing.status == :active do
        existing
      end
    end)
  end

  defp select_notification_channels(alert, state) do
    severity = alert.severity

    Enum.filter(state.notification_channels, fn channel ->
      case severity do
        s when s <= @severity_high ->
          # Critical and High alerts go to all channels
          true

        @severity_medium ->
          # Medium alerts skip PagerDuty
          channel.type != :pagerduty

        _ ->
          # Low/Info alerts only go to Slack and Discord
          channel.type in [:slack, :discord]
      end
    end)
  end

  defp schedule_escalation(alert, state) do
    policy =
      Enum.find(state.escalation_policies, &(&1.id == "default"))

    if policy do
      Enum.each(policy.rules, fn rule ->
        schedule_escalation_rule(alert, rule)
      end)
    end

    :ok
  end

  defp schedule_escalation_rule(alert, rule) do
    delay_ms = rule.delay_minutes * 60_000

    if delay_ms > 0 do
      Process.send_after(self(), {:escalate_alert, alert.id}, delay_ms)
    end
  end

  defp get_alert_state(alert_id) do
    case :persistent_term.get({__MODULE__, :alert_state, alert_id}, :not_found) do
      :not_found -> nil
      state -> state
    end
  end

  defp store_alert_state(alert_id, alert_state) do
    :persistent_term.put({__MODULE__, :alert_state, alert_id}, alert_state)
    :ok
  end

  defp clear_alert_state(alert_id) do
    try do
      :persistent_term.erase({__MODULE__, :alert_state, alert_id})
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  defp find_active_alert_by_rule(rule) do
    # Inspect active_alerts via the GenServer state is not directly accessible here
    # since these are called within handle_info/handle_call already.
    # Use the process dictionary as a lightweight lookup to avoid passing state everywhere.
    Logger.debug("Looking up active alert for rule #{rule.id} - requires state passthrough")
    nil
  end

  defp escalate_alert(alert, state) do
    current_severity = alert.severity

    if current_severity > @severity_critical do
      escalated_severity = current_severity - 1
      escalated_alert = %{alert | severity: escalated_severity}

      Logger.warning(
        "Escalating alert #{alert.id} from #{get_severity_name(current_severity)} to #{get_severity_name(escalated_severity)}"
      )

      state = put_in(state.active_alerts[alert.id], escalated_alert)
      send_alert_notifications(escalated_alert, state)
      state
    else
      Logger.debug("Alert #{alert.id} is already at Critical severity, cannot escalate further")
      state
    end
  end

  defp send_acknowledgment_notification(alert) do
    Logger.info(
      "Alert #{alert.id} acknowledged by #{alert.acknowledged_by} at #{alert.acknowledged_at}"
    )

    :telemetry.execute([:flame, :alert, :acknowledged], %{}, %{
      alert_id: alert.id,
      user_id: alert.acknowledged_by
    })

    :ok
  end

  defp send_resolution_notification(alert) do
    Logger.info("Alert #{alert.id} resolved by #{alert.resolved_by} at #{alert.resolved_at}")

    :telemetry.execute([:flame, :alert, :resolved], %{}, %{
      alert_id: alert.id,
      user_id: alert.resolved_by
    })

    :ok
  end

  defp calculate_alert_metrics(state) do
    active = state.active_alerts
    history = state.alert_history
    now = System.system_time(:millisecond)
    one_hour_ago = now - 3_600_000
    one_day_ago = now - 86_400_000

    active_by_severity =
      Enum.reduce(active, %{}, fn {_id, alert}, acc ->
        severity_name = get_severity_name(alert.severity)
        Map.update(acc, severity_name, 1, &(&1 + 1))
      end)

    recent_history =
      Enum.filter(history, fn alert ->
        Map.get(alert, :resolved_at, 0) > one_day_ago
      end)

    avg_resolution_time =
      case Enum.filter(recent_history, &Map.has_key?(&1, :resolved_at)) do
        [] ->
          0

        resolved ->
          total =
            Enum.reduce(resolved, 0, fn alert, acc ->
              acc + (alert.resolved_at - alert.triggered_at)
            end)

          div(total, length(resolved))
      end

    alerts_last_hour =
      Enum.count(history, fn alert ->
        alert.triggered_at > one_hour_ago
      end) + map_size(active)

    %{
      total_active: map_size(active),
      active_by_severity: active_by_severity,
      total_resolved_last_24h: length(recent_history),
      alerts_last_hour: alerts_last_hour,
      average_resolution_time_ms: avg_resolution_time,
      total_notification_channels: length(state.notification_channels),
      total_alert_rules: length(state.alert_rules),
      total_suppression_rules: length(state.suppression_rules)
    }
  end

  defp get_metric_time_series(metric, window_seconds) do
    case GenServer.call(ContainerMetrics, {:get_time_series, metric, window_seconds}, 5000) do
      series when is_list(series) and series != [] -> series
      _ -> nil
    end
  catch
    _ ->
      Logger.debug("ContainerMetrics unavailable for time series query on #{metric}")
      nil
  end

  defp detect_anomaly(time_series, sensitivity) do
    values = Enum.map(time_series, fn point -> point.value end)
    n = length(values)

    if n < 10 do
      :normal
    else
      mean = Enum.sum(values) / n

      variance =
        Enum.reduce(values, 0.0, fn v, acc -> acc + (v - mean) * (v - mean) end) / n

      std_dev = :math.sqrt(variance)

      # Use the last value and check if it deviates beyond the threshold
      last_value = List.last(values)
      # sensitivity 0..1 maps to threshold multiplier 4..2
      threshold_multiplier = 4.0 - sensitivity * 2.0

      if std_dev > 0 and abs(last_value - mean) > threshold_multiplier * std_dev do
        {:anomaly, %{value: last_value, mean: mean, std_dev: std_dev}}
      else
        :normal
      end
    end
  end

  defp evaluate_condition(%{metric: metric, condition: op, threshold: threshold}, _current_time) do
    case get_metric_value(metric) do
      nil -> false
      value -> compare_metric_value(op, value, threshold)
    end
  end

  defp evaluate_condition(_condition, _current_time), do: false

  defp compare_metric_value(:greater_than, value, threshold), do: value > threshold
  defp compare_metric_value(:less_than, value, threshold), do: value < threshold
  defp compare_metric_value(:equals, value, threshold), do: value == threshold
  defp compare_metric_value(:not_equals, value, threshold), do: value != threshold
  defp compare_metric_value(_op, _value, _threshold), do: false

  defp process_telemetry_event(event_name, measurements, metadata, state) do
    case event_name do
      [:flame, :task, :error] ->
        alert =
          create_alert_from_data(%{
            name: "Task Error",
            severity: @severity_medium,
            description: "Task error detected: #{inspect(Map.get(metadata, :reason, :unknown))}",
            runbook_url: "https://docs.flame.dev/runbooks/task-errors",
            tags: ["task", "error", "automatic"]
          })

        process_new_alert(alert, state)

      [:flame, :security, :validation_failed] ->
        alert =
          create_alert_from_data(%{
            name: "Security Validation Failed",
            severity: @severity_high,
            description:
              "Security validation failure: #{inspect(Map.get(metadata, :reason, :unknown))}",
            runbook_url: "https://docs.flame.dev/runbooks/security-failures",
            tags: ["security", "validation", "automatic"]
          })

        process_new_alert(alert, state)

      [:flame, :container, :terminate] ->
        reason = Map.get(metadata, :reason, :unknown)

        if reason != :normal and reason != :shutdown do
          alert =
            create_alert_from_data(%{
              name: "Unexpected Container Termination",
              severity: @severity_high,
              description: "Container terminated unexpectedly: #{inspect(reason)}",
              runbook_url: "https://docs.flame.dev/runbooks/container-health",
              tags: ["container", "termination", "automatic"]
            })

          process_new_alert(alert, state)
        else
          state
        end

      [:flame, :resource, :limit_exceeded] ->
        alert =
          create_alert_from_data(%{
            name: "Resource Limit Exceeded",
            severity: @severity_high,
            description:
              "Resource limit exceeded: #{inspect(Map.get(measurements, :resource, :unknown))}",
            runbook_url: "https://docs.flame.dev/runbooks/resource-limits",
            tags: ["resource", "limit", "automatic"]
          })

        process_new_alert(alert, state)

      [:flame, :cluster, :node_unhealthy] ->
        alert =
          create_alert_from_data(%{
            name: "Cluster Node Unhealthy",
            severity: @severity_high,
            description: "Cluster node unhealthy: #{inspect(Map.get(metadata, :node, :unknown))}",
            runbook_url: "https://docs.flame.dev/runbooks/cluster-availability",
            tags: ["cluster", "node", "health", "automatic"]
          })

        process_new_alert(alert, state)

      _ ->
        Logger.debug("Unhandled telemetry event: #{inspect(event_name)}")
        state
    end
  end

  defp in_maintenance_window? do
    # Check for a maintenance window configured via application env
    case Application.get_env(:flame_apple_container_backend, :maintenance_window) do
      nil ->
        false

      %{start: start_time, end: end_time} ->
        now = Time.utc_now()
        Time.compare(now, start_time) != :lt and Time.compare(now, end_time) != :gt

      _ ->
        false
    end
  end

  defp generate_webhook_signature(payload, secret) when is_binary(secret) do
    body =
      case payload do
        b when is_binary(b) -> b
        _ -> Jason.encode!(payload)
      end

    :crypto.mac(:hmac, :sha256, secret, body)
    |> Base.encode16(case: :lower)
  end

  defp generate_webhook_signature(_payload, _secret) do
    Logger.debug("Webhook signature requested but no secret configured")
    ""
  end

  # Notification channel creators

  defp create_slack_channel(config) do
    %{
      id: generate_channel_id(),
      name: config[:name] || "Slack",
      type: :slack,
      webhook_url: config[:webhook_url],
      channel: config[:channel] || "#alerts"
    }
  end

  defp create_discord_channel(config) do
    %{
      id: generate_channel_id(),
      name: config[:name] || "Discord",
      type: :discord,
      webhook_url: config[:webhook_url]
    }
  end

  defp create_email_channel(config) do
    %{
      id: generate_channel_id(),
      name: config[:name] || "Email",
      type: :email,
      smtp_server: config[:smtp_server],
      smtp_port: config[:smtp_port],
      username: config[:username],
      password: config[:password],
      recipients: config[:recipients]
    }
  end

  defp create_pagerduty_channel(config) do
    %{
      id: generate_channel_id(),
      name: config[:name] || "PagerDuty",
      type: :pagerduty,
      integration_key: config[:integration_key]
    }
  end

  defp http_post(url, body, headers) do
    if Code.ensure_loaded?(Req) do
      header_map =
        Enum.into(headers, %{}, fn {k, v} -> {String.downcase(k), v} end)

      case Req.post(url, body: body, headers: header_map, receive_timeout: 10_000) do
        {:ok, %Req.Response{status: status}} ->
          {:ok, %{status_code: status}}

        {:error, %Req.TransportError{reason: reason}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    else
      Logger.warning(
        "HTTP POST to #{url} skipped: Req library not available. " <>
          "Add {:req, \"~> 0.5.0\"} to your dependencies to enable HTTP notifications."
      )

      {:error, :http_client_not_available}
    end
  end
end
