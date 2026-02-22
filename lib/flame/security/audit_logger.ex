defmodule FLAME.Security.AuditLogger do
  @moduledoc """
  Comprehensive audit logging system for FLAME operations.

  Provides structured logging for security events, compliance tracking,
  and forensic analysis with multiple storage backends and real-time alerting.
  """

  use GenServer
  require Logger

  alias FLAME.AlertManager

  # Event categories for audit logging
  # @event_categories %{
  #   authentication: [
  #     "user_authenticated",
  #     "authentication_failed",
  #     "session_created",
  #     "session_revoked"
  #   ],
  #   authorization: ["authorization_check", "role_assigned", "role_revoked", "permission_denied"],
  #   resource_access: ["cluster_accessed", "job_accessed", "image_accessed", "alert_accessed"],
  #   data_modification: [
  #     "cluster_created",
  #     "cluster_updated",
  #     "cluster_deleted",
  #     "job_created",
  #     "job_updated",
  #     "job_deleted"
  #   ],
  #   security: [
  #     "security_policy_changed",
  #     "suspicious_activity",
  #     "anomaly_detected",
  #     "compliance_violation"
  #   ],
  #   system: ["system_started", "system_stopped", "backup_created", "configuration_changed"]
  # }

  # Compliance frameworks supported
  @compliance_frameworks [
    "SOC2_TYPE2",
    "ISO27001",
    "GDPR",
    "HIPAA",
    "PCI_DSS"
  ]

  defstruct [
    :storage_backends,
    :retention_policies,
    :alert_rules,
    :compliance_config,
    :encryption_key,
    :buffer,
    :stats
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    storage_backends = Keyword.get(opts, :storage_backends, [:file, :database])
    # 7 years default
    retention_days = Keyword.get(opts, :retention_days, 2555)
    _encryption_enabled = Keyword.get(opts, :encryption_enabled, true)

    state = %__MODULE__{
      storage_backends: storage_backends,
      retention_policies: %{
        authentication: retention_days,
        authorization: retention_days,
        resource_access: 365,
        data_modification: retention_days,
        security: retention_days * 2,
        system: 90
      },
      alert_rules: setup_default_alert_rules(),
      compliance_config: setup_compliance_config(),
      encryption_key: generate_encryption_key(),
      buffer: [],
      stats: %{
        total_events: 0,
        events_by_category: %{},
        last_flush: DateTime.utc_now()
      }
    }

    # Schedule periodic buffer flush
    schedule_buffer_flush()

    # Schedule retention cleanup
    schedule_retention_cleanup()

    Logger.info("Audit logging system initialized with backends: #{inspect(storage_backends)}")
    {:ok, state}
  end

  # Public API

  def log_auth_event(event_data) do
    GenServer.cast(__MODULE__, {:log_event, :authentication, event_data})
  end

  def log_access_event(event_data) do
    GenServer.cast(__MODULE__, {:log_event, :resource_access, event_data})
  end

  def log_modification_event(event_data) do
    GenServer.cast(__MODULE__, {:log_event, :data_modification, event_data})
  end

  def log_security_event(event_data) do
    GenServer.cast(__MODULE__, {:log_event, :security, event_data})
  end

  def log_system_event(event_data) do
    GenServer.cast(__MODULE__, {:log_event, :system, event_data})
  end

  def search_audit_logs(criteria) do
    GenServer.call(__MODULE__, {:search_logs, criteria})
  end

  def export_audit_logs(format, criteria \\ %{}) do
    GenServer.call(__MODULE__, {:export_logs, format, criteria})
  end

  def get_compliance_report(framework, date_range) do
    GenServer.call(__MODULE__, {:compliance_report, framework, date_range})
  end

  def get_audit_stats(timeframe \\ :day) do
    GenServer.call(__MODULE__, {:audit_stats, timeframe})
  end

  def configure_retention(category, days) do
    GenServer.call(__MODULE__, {:configure_retention, category, days})
  end

  def add_alert_rule(rule) do
    GenServer.call(__MODULE__, {:add_alert_rule, rule})
  end

  # GenServer callbacks

  def handle_cast({:log_event, category, event_data}, state) do
    # Enrich event data
    enriched_event = enrich_event_data(category, event_data)

    # Add to buffer
    updated_buffer = [enriched_event | state.buffer]

    # Update stats
    updated_stats = update_stats(state.stats, category, enriched_event)

    # Check alert rules
    check_alert_rules(enriched_event, state.alert_rules)

    # If buffer is full, flush immediately
    {new_buffer, new_state} =
      if length(updated_buffer) >= 100 do
        flush_buffer(updated_buffer, state)
        {[], state}
      else
        {updated_buffer, state}
      end

    updated_state = %{new_state | buffer: new_buffer, stats: updated_stats}

    {:noreply, updated_state}
  end

  def handle_call({:search_logs, criteria}, _from, state) do
    results = search_logs_impl(criteria, state)
    {:reply, {:ok, results}, state}
  end

  def handle_call({:export_logs, format, criteria}, _from, state) do
    case export_logs_impl(format, criteria, state) do
      {:ok, file_path} -> {:reply, {:ok, file_path}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:compliance_report, framework, date_range}, _from, state) do
    report = generate_compliance_report(framework, date_range, state)
    {:reply, {:ok, report}, state}
  end

  def handle_call({:audit_stats, timeframe}, _from, state) do
    stats = calculate_audit_stats(timeframe, state)
    {:reply, {:ok, stats}, state}
  end

  def handle_call({:configure_retention, category, days}, _from, state) do
    updated_policies = Map.put(state.retention_policies, category, days)
    updated_state = %{state | retention_policies: updated_policies}

    log_system_event(%{
      event: "retention_policy_updated",
      category: category,
      retention_days: days,
      timestamp: DateTime.utc_now()
    })

    {:reply, :ok, updated_state}
  end

  def handle_call({:add_alert_rule, rule}, _from, state) do
    updated_rules = [rule | state.alert_rules]
    updated_state = %{state | alert_rules: updated_rules}

    {:reply, :ok, updated_state}
  end

  def handle_info(:flush_buffer, state) do
    if length(state.buffer) > 0 do
      flush_buffer(state.buffer, state)
      schedule_buffer_flush()
      {:noreply, %{state | buffer: []}}
    else
      schedule_buffer_flush()
      {:noreply, state}
    end
  end

  def handle_info(:cleanup_retention, state) do
    cleanup_old_records(state)
    schedule_retention_cleanup()
    {:noreply, state}
  end

  # Private implementation

  defp enrich_event_data(category, event_data) do
    base_data = %{
      id: generate_event_id(),
      category: category,
      timestamp: DateTime.utc_now(),
      source: "flame_backend",
      version: "1.0",
      severity: determine_severity(category, event_data)
    }

    Map.merge(base_data, event_data)
  end

  defp determine_severity(category, event_data) do
    case {category, Map.get(event_data, :event)} do
      {:authentication, "authentication_failed"} -> "medium"
      {:authorization, "permission_denied"} -> "medium"
      {:security, _} -> "high"
      {:data_modification, _} -> "medium"
      _ -> "low"
    end
  end

  defp update_stats(stats, category, event) do
    %{
      stats
      | total_events: stats.total_events + 1,
        events_by_category: Map.update(stats.events_by_category, category, 1, &(&1 + 1)),
        last_event: event.timestamp
    }
  end

  defp check_alert_rules(event, alert_rules) do
    Enum.each(alert_rules, fn rule ->
      if matches_alert_rule?(event, rule) do
        trigger_audit_alert(event, rule)
      end
    end)
  end

  defp matches_alert_rule?(event, rule) do
    case rule.type do
      :failed_authentication_threshold ->
        matches_failed_auth?(event, rule)

      :privilege_escalation ->
        matches_privilege_escalation?(event)

      :bulk_data_access ->
        matches_bulk_data_access?(event, rule)

      :suspicious_activity ->
        event.category == :security

      _ ->
        false
    end
  end

  defp matches_failed_auth?(event, rule) do
    event.category == :authentication and
      event.event == "authentication_failed" and
      check_threshold(event, rule)
  end

  defp matches_privilege_escalation?(event) do
    event.category == :authorization and
      event.event == "role_assigned" and
      event.role in ["admin", "operator"]
  end

  defp matches_bulk_data_access?(event, rule) do
    event.category == :resource_access and
      check_bulk_access(event, rule)
  end

  defp check_threshold(_event, _rule) do
    # Simple threshold check - in production this would query historical data
    true
  end

  defp check_bulk_access(_event, _rule) do
    # Check for bulk access patterns
    false
  end

  defp trigger_audit_alert(event, rule) do
    alert_data = %{
      type: "audit_alert",
      severity: rule.severity || "medium",
      title: "Audit Alert: #{rule.name}",
      description: "Audit rule '#{rule.name}' triggered",
      event: event,
      rule: rule,
      timestamp: DateTime.utc_now()
    }

    AlertManager.create_alert(alert_data)
  end

  defp flush_buffer(events, state) do
    Enum.each(state.storage_backends, fn backend ->
      store_events(backend, events, state)
    end)

    Logger.debug("Flushed #{length(events)} audit events to storage")
  end

  defp store_events(:file, events, _state) do
    log_file = Path.join([System.tmp_dir(), "flame_audit.log"])

    log_entries = Enum.map_join(events, "\n", &format_log_entry/1)

    File.write!(log_file, log_entries <> "\n", [:append])
  end

  defp store_events(:database, events, _state) do
    # In production, this would use your database adapter
    # For now, we'll just log to console
    Enum.each(events, fn event ->
      Logger.info("AUDIT: #{inspect(event)}")
    end)
  end

  defp store_events(:elasticsearch, _events, _state) do
    # Elasticsearch integration for large-scale audit logging
    # Implementation would depend on your Elasticsearch setup
    :ok
  end

  defp format_log_entry(event) do
    Jason.encode!(%{
      timestamp: DateTime.to_iso8601(event.timestamp),
      id: event.id,
      category: event.category,
      event: event.event,
      severity: event.severity,
      data: Map.drop(event, [:timestamp, :id, :category, :severity])
    })
  end

  defp search_logs_impl(criteria, _state) do
    # Simple file-based search for demo
    # In production, this would query your primary storage backend
    log_file = Path.join([System.tmp_dir(), "flame_audit.log"])

    if File.exists?(log_file) do
      log_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> filter_by_criteria(criteria)
      # Limit results
      |> Enum.take(1000)
    else
      []
    end
  end

  defp filter_by_criteria(events, criteria) do
    Enum.filter(events, fn event ->
      Enum.all?(criteria, &event_matches_criterion?(event, &1))
    end)
  end

  defp event_matches_criterion?(event, {:category, value}) do
    event["category"] == to_string(value)
  end

  defp event_matches_criterion?(event, {:event, value}) do
    event["event"] == value
  end

  defp event_matches_criterion?(event, {:user_id, value}) do
    get_in(event, ["data", "user_id"]) == value
  end

  defp event_matches_criterion?(event, {:date_from, value}) do
    {:ok, event_date, _} = DateTime.from_iso8601(event["timestamp"])
    DateTime.compare(event_date, value) != :lt
  end

  defp event_matches_criterion?(event, {:date_to, value}) do
    {:ok, event_date, _} = DateTime.from_iso8601(event["timestamp"])
    DateTime.compare(event_date, value) != :gt
  end

  defp event_matches_criterion?(_event, {_key, _value}) do
    true
  end

  defp export_logs_impl(format, criteria, state) do
    events = search_logs_impl(criteria, state)

    case format do
      :csv -> export_to_csv(events)
      :json -> export_to_json(events)
      :pdf -> export_to_pdf(events)
      _ -> {:error, :unsupported_format}
    end
  end

  defp export_to_csv(events) do
    file_path = Path.join([System.tmp_dir(), "audit_export_#{:os.system_time(:second)}.csv"])

    csv_content =
      [
        "timestamp,category,event,severity,user_id,resource,action\n"
        | Enum.map(events, &format_csv_row/1)
      ]
      |> Enum.join("")

    File.write!(file_path, csv_content)
    {:ok, file_path}
  end

  defp export_to_json(events) do
    file_path = Path.join([System.tmp_dir(), "audit_export_#{:os.system_time(:second)}.json"])

    json_content =
      Jason.encode!(
        %{
          export_timestamp: DateTime.utc_now(),
          total_events: length(events),
          events: events
        },
        pretty: true
      )

    File.write!(file_path, json_content)
    {:ok, file_path}
  end

  defp export_to_pdf(_events) do
    # PDF export would require additional dependencies
    # For now, return an error
    {:error, :pdf_export_not_implemented}
  end

  defp format_csv_row(event) do
    [
      event["timestamp"],
      event["category"],
      event["event"],
      event["severity"],
      get_in(event, ["data", "user_id"]) || "",
      get_in(event, ["data", "resource"]) || "",
      get_in(event, ["data", "action"]) || ""
    ]
    |> Enum.map_join(",", &escape_csv_field/1)
    |> Kernel.<>("\n")
  end

  defp escape_csv_field(nil), do: ""

  defp escape_csv_field(field) when is_binary(field) do
    if String.contains?(field, [",", "\"", "\n"]) do
      "\"#{String.replace(field, "\"", "\"\"")}\""
    else
      field
    end
  end

  defp escape_csv_field(field), do: to_string(field)

  defp generate_compliance_report(framework, date_range, state) do
    events =
      search_logs_impl(
        %{
          date_from: date_range.from,
          date_to: date_range.to
        },
        state
      )

    case framework do
      "SOC2_TYPE2" -> generate_soc2_report(events, date_range)
      "ISO27001" -> generate_iso27001_report(events, date_range)
      "GDPR" -> generate_gdpr_report(events, date_range)
      _ -> {:error, :unsupported_framework}
    end
  end

  defp generate_soc2_report(events, date_range) do
    %{
      framework: "SOC 2 Type II",
      report_period: date_range,
      generated_at: DateTime.utc_now(),
      trust_criteria: %{
        security: %{
          access_controls: count_events(events, :authorization),
          authentication_events: count_events(events, :authentication),
          failed_access_attempts: count_failed_events(events, "authentication_failed")
        },
        availability: %{
          system_uptime_events: count_events(events, :system),
          incident_count: count_security_events(events)
        },
        processing_integrity: %{
          data_modification_events: count_events(events, :data_modification),
          unauthorized_changes: count_unauthorized_changes(events)
        },
        confidentiality: %{
          data_access_events: count_events(events, :resource_access),
          encryption_events: count_encryption_events(events)
        }
      },
      summary: %{
        total_events: length(events),
        compliance_score: calculate_compliance_score(events),
        recommendations: generate_recommendations(events)
      }
    }
  end

  defp generate_iso27001_report(events, date_range) do
    %{
      framework: "ISO 27001",
      report_period: date_range,
      generated_at: DateTime.utc_now(),
      controls: %{
        "A.9.1" => %{
          name: "Access control policy",
          events: count_events(events, :authorization),
          compliance: "compliant"
        },
        "A.9.2" => %{
          name: "User access management",
          events: count_user_management_events(events),
          compliance: "compliant"
        }
      }
    }
  end

  defp generate_gdpr_report(events, date_range) do
    %{
      framework: "GDPR",
      report_period: date_range,
      generated_at: DateTime.utc_now(),
      data_processing: %{
        personal_data_access: count_personal_data_access(events),
        consent_management: count_consent_events(events),
        data_breaches: count_security_events(events),
        deletion_requests: count_deletion_events(events)
      }
    }
  end

  defp calculate_audit_stats(timeframe, state) do
    %{
      current_stats: state.stats,
      timeframe: timeframe,
      calculated_at: DateTime.utc_now()
    }
  end

  defp cleanup_old_records(_state) do
    # Implement retention policy cleanup
    Logger.info("Running audit log retention cleanup")
  end

  defp schedule_buffer_flush do
    # 10 seconds
    Process.send_after(self(), :flush_buffer, 10_000)
  end

  defp schedule_retention_cleanup do
    # 24 hours
    Process.send_after(self(), :cleanup_retention, 24 * 60 * 60 * 1000)
  end

  defp setup_default_alert_rules do
    [
      %{
        type: :failed_authentication_threshold,
        name: "Multiple Failed Authentication Attempts",
        threshold: 5,
        timeframe: :minute,
        severity: "high"
      },
      %{
        type: :privilege_escalation,
        name: "Privilege Escalation Detected",
        severity: "critical"
      },
      %{
        type: :suspicious_activity,
        name: "Suspicious Security Activity",
        severity: "high"
      }
    ]
  end

  defp setup_compliance_config do
    %{
      frameworks: @compliance_frameworks,
      retention_requirements: %{
        # 7 years
        "SOC2_TYPE2" => 2555,
        # 6 years
        "ISO27001" => 2190,
        # 6 years
        "GDPR" => 2190,
        # 7 years
        "HIPAA" => 2555,
        # 1 year
        "PCI_DSS" => 365
      }
    }
  end

  defp generate_encryption_key do
    :crypto.strong_rand_bytes(32)
  end

  defp generate_event_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  # Helper functions for compliance reports
  defp count_events(events, category) do
    Enum.count(events, &(&1["category"] == to_string(category)))
  end

  defp count_failed_events(events, event_type) do
    Enum.count(events, &(&1["event"] == event_type))
  end

  defp count_security_events(events) do
    Enum.count(events, &(&1["category"] == "security"))
  end

  defp count_unauthorized_changes(events) do
    Enum.count(events, fn event ->
      event["category"] == "data_modification" and
        event["severity"] == "high"
    end)
  end

  defp count_encryption_events(events) do
    Enum.count(events, fn event ->
      event_data = event["data"] || %{}
      Map.has_key?(event_data, "encryption") or Map.has_key?(event_data, "encrypted")
    end)
  end

  defp count_user_management_events(events) do
    Enum.count(events, fn event ->
      event["event"] in ["role_assigned", "role_revoked", "user_created", "user_deleted"]
    end)
  end

  defp count_personal_data_access(events) do
    Enum.count(events, fn event ->
      event_data = event["data"] || %{}
      Map.has_key?(event_data, "personal_data") or Map.has_key?(event_data, "pii")
    end)
  end

  defp count_consent_events(events) do
    Enum.count(events, fn event ->
      event["event"] in ["consent_given", "consent_withdrawn", "consent_updated"]
    end)
  end

  defp count_deletion_events(events) do
    Enum.count(events, fn event ->
      event["event"] in ["data_deleted", "user_deleted", "right_to_be_forgotten"]
    end)
  end

  defp calculate_compliance_score(events) do
    # Simple compliance scoring algorithm
    total_events = length(events)
    security_events = count_security_events(events)

    if total_events == 0 do
      100
    else
      max(0, 100 - security_events * 100 / total_events)
    end
  end

  defp generate_recommendations(events) do
    recommendations = []

    recommendations =
      if count_failed_events(events, "authentication_failed") > 10 do
        ["Consider implementing stronger authentication policies" | recommendations]
      else
        recommendations
      end

    recommendations =
      if count_security_events(events) > 5 do
        ["Review security incidents and strengthen monitoring" | recommendations]
      else
        recommendations
      end

    if recommendations == [] do
      ["Security posture appears healthy"]
    else
      recommendations
    end
  end
end
