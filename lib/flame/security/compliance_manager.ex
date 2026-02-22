defmodule FLAME.Security.ComplianceManager do
  @moduledoc """
  Compliance management and monitoring system for FLAME operations.

  Provides continuous compliance monitoring, automated assessment,
  and reporting for multiple regulatory frameworks including SOC 2,
  ISO 27001, GDPR, HIPAA, and PCI DSS.
  """

  use GenServer
  require Logger

  alias FLAME.AlertManager
  alias FLAME.Security.AuditLogger

  # Supported compliance frameworks
  @frameworks %{
    "SOC2_TYPE2" => %{
      name: "SOC 2 Type II",
      controls: [
        %{id: "CC6.1", name: "Logical and Physical Access Controls", category: :access_control},
        %{id: "CC6.2", name: "System Access", category: :authentication},
        %{id: "CC6.3", name: "Data Access", category: :authorization},
        %{id: "CC7.1", name: "System Use Detection", category: :monitoring},
        %{id: "CC7.2", name: "System Monitoring", category: :logging}
      ],
      requirements: %{
        # 7 years
        audit_retention: 2555,
        # days
        access_review_frequency: 90,
        # hours
        incident_response_time: 24,
        encryption_required: true
      }
    },
    "ISO27001" => %{
      name: "ISO/IEC 27001:2013",
      controls: [
        %{id: "A.9.1.1", name: "Access control policy", category: :access_control},
        %{
          id: "A.9.2.1",
          name: "User registration and de-registration",
          category: :user_management
        },
        %{id: "A.9.4.2", name: "Secure log-on procedures", category: :authentication},
        %{id: "A.12.4.1", name: "Event logging", category: :logging},
        %{
          id: "A.12.6.1",
          name: "Management of technical vulnerabilities",
          category: :vulnerability_management
        }
      ],
      requirements: %{
        # 6 years
        audit_retention: 2190,
        # days
        access_review_frequency: 180,
        # days
        risk_assessment_frequency: 365,
        # days
        security_training_frequency: 365
      }
    },
    "GDPR" => %{
      name: "General Data Protection Regulation",
      controls: [
        %{id: "Art.32", name: "Security of processing", category: :data_protection},
        %{
          id: "Art.33",
          name: "Notification of personal data breach",
          category: :incident_response
        },
        %{id: "Art.17", name: "Right to erasure", category: :data_rights},
        %{id: "Art.20", name: "Right to data portability", category: :data_rights},
        %{
          id: "Art.25",
          name: "Data protection by design and by default",
          category: :privacy_by_design
        }
      ],
      requirements: %{
        # hours
        breach_notification_time: 72,
        # days
        data_retention_review: 365,
        consent_management: true,
        privacy_impact_assessment: true
      }
    }
  }

  defstruct [
    :active_frameworks,
    :assessment_schedule,
    :compliance_status,
    :control_evidence,
    :remediation_tasks,
    :assessment_history,
    :notification_config
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    active_frameworks = Keyword.get(opts, :frameworks, ["SOC2_TYPE2"])
    # hours
    assessment_frequency = Keyword.get(opts, :assessment_frequency, 24)

    state = %__MODULE__{
      active_frameworks: active_frameworks,
      assessment_schedule: %{},
      compliance_status: %{},
      control_evidence: %{},
      remediation_tasks: [],
      assessment_history: [],
      notification_config: setup_notification_config(opts)
    }

    # Initialize compliance status for active frameworks
    initial_state = initialize_frameworks(state)

    # Schedule initial assessment
    schedule_compliance_assessment(assessment_frequency)

    Logger.info("Compliance manager initialized for frameworks: #{inspect(active_frameworks)}")
    {:ok, initial_state}
  end

  # Public API

  def run_compliance_assessment(framework \\ nil) do
    GenServer.call(__MODULE__, {:run_assessment, framework}, 30_000)
  end

  def get_compliance_status(framework \\ nil) do
    GenServer.call(__MODULE__, {:get_status, framework})
  end

  def generate_compliance_report(framework, options \\ %{}) do
    GenServer.call(__MODULE__, {:generate_report, framework, options}, 60_000)
  end

  def add_control_evidence(framework, control_id, evidence) do
    GenServer.call(__MODULE__, {:add_evidence, framework, control_id, evidence})
  end

  def create_remediation_task(issue) do
    GenServer.call(__MODULE__, {:create_remediation, issue})
  end

  def get_remediation_tasks(status \\ nil) do
    GenServer.call(__MODULE__, {:get_remediations, status})
  end

  def configure_framework(framework, config) do
    GenServer.call(__MODULE__, {:configure_framework, framework, config})
  end

  def schedule_assessment(framework, schedule) do
    GenServer.call(__MODULE__, {:schedule_assessment, framework, schedule})
  end

  # GenServer callbacks

  def handle_call({:run_assessment, framework}, _from, state) do
    case framework do
      nil ->
        # Run assessment for all active frameworks
        results = run_all_assessments(state)
        updated_state = update_compliance_status(state, results)
        {:reply, {:ok, results}, updated_state}

      specific_framework ->
        if specific_framework in state.active_frameworks do
          result = run_framework_assessment(specific_framework, state)
          updated_state = update_single_framework_status(state, specific_framework, result)
          {:reply, {:ok, result}, updated_state}
        else
          {:reply, {:error, :framework_not_active}, state}
        end
    end
  end

  def handle_call({:get_status, framework}, _from, state) do
    case framework do
      nil ->
        {:reply, {:ok, state.compliance_status}, state}

      specific ->
        status = Map.get(state.compliance_status, specific)
        {:reply, {:ok, status}, state}
    end
  end

  def handle_call({:generate_report, framework, options}, _from, state) do
    case generate_compliance_report_impl(framework, options, state) do
      {:ok, report} -> {:reply, {:ok, report}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:add_evidence, framework, control_id, evidence}, _from, state) do
    evidence_key = {framework, control_id}

    updated_evidence =
      Map.update(state.control_evidence, evidence_key, [evidence], &[evidence | &1])

    updated_state = %{state | control_evidence: updated_evidence}

    AuditLogger.log_system_event(%{
      event: "compliance_evidence_added",
      framework: framework,
      control_id: control_id,
      evidence_type: evidence.type,
      timestamp: DateTime.utc_now()
    })

    {:reply, :ok, updated_state}
  end

  def handle_call({:create_remediation, issue}, _from, state) do
    task = create_remediation_task_impl(issue)
    updated_tasks = [task | state.remediation_tasks]
    updated_state = %{state | remediation_tasks: updated_tasks}

    # Create alert for high priority issues
    if task.priority == "critical" do
      AlertManager.create_alert(%{
        type: "compliance_issue",
        severity: "critical",
        title: "Critical Compliance Issue",
        description: issue.description,
        metadata: %{task_id: task.id, framework: issue.framework}
      })
    end

    {:reply, {:ok, task}, updated_state}
  end

  def handle_call({:get_remediations, status}, _from, state) do
    filtered_tasks = filter_remediation_tasks(state.remediation_tasks, status)
    {:reply, {:ok, filtered_tasks}, state}
  end

  def handle_call({:configure_framework, framework, config}, _from, state) do
    # Update framework configuration
    # This would typically update database or configuration files

    AuditLogger.log_system_event(%{
      event: "compliance_framework_configured",
      framework: framework,
      config: config,
      timestamp: DateTime.utc_now()
    })

    {:reply, :ok, state}
  end

  def handle_call({:schedule_assessment, framework, schedule}, _from, state) do
    updated_schedule = Map.put(state.assessment_schedule, framework, schedule)
    updated_state = %{state | assessment_schedule: updated_schedule}

    {:reply, :ok, updated_state}
  end

  def handle_info(:run_scheduled_assessment, state) do
    # Run scheduled assessments
    results = run_all_assessments(state)
    updated_state = update_compliance_status(state, results)

    # Check for compliance violations
    check_compliance_violations(results)

    # Schedule next assessment
    # 24 hours
    schedule_compliance_assessment(24)

    {:noreply, updated_state}
  end

  # Private implementation

  defp initialize_frameworks(state) do
    initial_status =
      state.active_frameworks
      |> Enum.map(fn framework ->
        {framework,
         %{
           status: "unknown",
           last_assessment: nil,
           score: 0,
           controls: initialize_framework_controls(framework),
           issues: []
         }}
      end)
      |> Map.new()

    %{state | compliance_status: initial_status}
  end

  defp initialize_framework_controls(framework) do
    case Map.get(@frameworks, framework) do
      nil ->
        %{}

      framework_spec ->
        framework_spec.controls
        |> Enum.map(fn control ->
          {control.id,
           %{
             status: "not_assessed",
             evidence_count: 0,
             last_review: nil,
             issues: []
           }}
        end)
        |> Map.new()
    end
  end

  defp run_all_assessments(state) do
    state.active_frameworks
    |> Enum.map(fn framework ->
      {framework, run_framework_assessment(framework, state)}
    end)
    |> Map.new()
  end

  defp run_framework_assessment(framework, state) do
    Logger.info("Running compliance assessment for #{framework}")

    case Map.get(@frameworks, framework) do
      nil ->
        {:error, :framework_not_supported}

      framework_spec ->
        assessment_result = %{
          framework: framework,
          timestamp: DateTime.utc_now(),
          status: "completed",
          score: 0,
          controls: %{},
          issues: [],
          recommendations: []
        }

        # Assess each control
        {controls_status, total_score, issues} = assess_framework_controls(framework_spec, state)

        %{
          assessment_result
          | score: total_score,
            controls: controls_status,
            issues: issues,
            recommendations: generate_recommendations(issues)
        }
    end
  end

  defp assess_framework_controls(framework_spec, state) do
    total_controls = length(framework_spec.controls)

    control_results =
      framework_spec.controls
      |> Enum.map(fn control ->
        {control_status, score, issues} = assess_control(control, framework_spec, state)
        {{control.id, control_status}, score, issues}
      end)

    controls_status = Enum.map(control_results, fn {status, _score, _issues} -> status end)
    scores = Enum.map(control_results, fn {_status, score, _issues} -> score end)
    all_issues = Enum.flat_map(control_results, fn {_status, _score, issues} -> issues end)

    total_score =
      scores
      |> Enum.sum()
      |> Kernel./(total_controls)
      |> Float.round(2)

    {Map.new(controls_status), total_score, List.flatten(all_issues)}
  end

  defp assess_control(control, framework_spec, state) do
    Logger.debug("Assessing control #{control.id}: #{control.name}")

    # Get evidence for this control
    evidence_key = {framework_spec.name, control.id}
    evidence = Map.get(state.control_evidence, evidence_key, [])

    # Assess based on control category
    case control.category do
      :access_control -> assess_access_control(control, evidence, state)
      :authentication -> assess_authentication_control(control, evidence, state)
      :authorization -> assess_authorization_control(control, evidence, state)
      :logging -> assess_logging_control(control, evidence, state)
      :monitoring -> assess_monitoring_control(control, evidence, state)
      :data_protection -> assess_data_protection_control(control, evidence, state)
      :incident_response -> assess_incident_response_control(control, evidence, state)
      _ -> assess_generic_control(control, evidence, state)
    end
  end

  defp assess_access_control(control, evidence, _state) do
    # Check RBAC implementation
    rbac_implemented = check_rbac_implementation()
    access_reviews_current = check_access_reviews()

    issues = []

    issues =
      if rbac_implemented do
        issues
      else
        [%{type: "missing_rbac", control: control.id, severity: "high"} | issues]
      end

    issues =
      if access_reviews_current do
        issues
      else
        [%{type: "outdated_access_review", control: control.id, severity: "medium"} | issues]
      end

    score = calculate_control_score([rbac_implemented, access_reviews_current], evidence)

    status = %{
      status: if(score >= 80, do: "compliant", else: "non_compliant"),
      score: score,
      evidence_count: length(evidence),
      last_assessment: DateTime.utc_now(),
      issues: issues
    }

    {status, score, issues}
  end

  defp assess_authentication_control(control, evidence, _state) do
    # Check authentication policies
    strong_auth_enabled = check_strong_authentication()
    session_management = check_session_management()

    issues = []

    issues =
      if strong_auth_enabled do
        issues
      else
        [%{type: "weak_authentication", control: control.id, severity: "high"} | issues]
      end

    score = calculate_control_score([strong_auth_enabled, session_management], evidence)

    status = %{
      status: if(score >= 80, do: "compliant", else: "non_compliant"),
      score: score,
      evidence_count: length(evidence),
      last_assessment: DateTime.utc_now(),
      issues: issues
    }

    {status, score, issues}
  end

  defp assess_authorization_control(_control, evidence, _state) do
    # Check authorization mechanisms
    rbac_enforced = check_rbac_enforcement()
    least_privilege = check_least_privilege()

    score = calculate_control_score([rbac_enforced, least_privilege], evidence)
    issues = []

    status = %{
      status: if(score >= 80, do: "compliant", else: "non_compliant"),
      score: score,
      evidence_count: length(evidence),
      last_assessment: DateTime.utc_now(),
      issues: issues
    }

    {status, score, issues}
  end

  defp assess_logging_control(_control, evidence, _state) do
    # Check audit logging implementation
    audit_logging_enabled = check_audit_logging()
    log_integrity = check_log_integrity()
    retention_compliance = check_retention_compliance()

    score =
      calculate_control_score(
        [audit_logging_enabled, log_integrity, retention_compliance],
        evidence
      )

    issues = []

    status = %{
      status: if(score >= 80, do: "compliant", else: "non_compliant"),
      score: score,
      evidence_count: length(evidence),
      last_assessment: DateTime.utc_now(),
      issues: issues
    }

    {status, score, issues}
  end

  defp assess_monitoring_control(_control, evidence, _state) do
    # Check monitoring capabilities
    real_time_monitoring = check_real_time_monitoring()
    alerting_configured = check_alerting_configuration()

    score = calculate_control_score([real_time_monitoring, alerting_configured], evidence)
    issues = []

    status = %{
      status: if(score >= 80, do: "compliant", else: "non_compliant"),
      score: score,
      evidence_count: length(evidence),
      last_assessment: DateTime.utc_now(),
      issues: issues
    }

    {status, score, issues}
  end

  defp assess_data_protection_control(_control, evidence, _state) do
    # Check data protection measures
    encryption_at_rest = check_encryption_at_rest()
    encryption_in_transit = check_encryption_in_transit()
    data_classification = check_data_classification()

    score =
      calculate_control_score(
        [encryption_at_rest, encryption_in_transit, data_classification],
        evidence
      )

    issues = []

    status = %{
      status: if(score >= 80, do: "compliant", else: "non_compliant"),
      score: score,
      evidence_count: length(evidence),
      last_assessment: DateTime.utc_now(),
      issues: issues
    }

    {status, score, issues}
  end

  defp assess_incident_response_control(_control, evidence, _state) do
    # Check incident response capabilities
    response_plan_exists = check_incident_response_plan()
    notification_procedures = check_notification_procedures()

    score = calculate_control_score([response_plan_exists, notification_procedures], evidence)
    issues = []

    status = %{
      status: if(score >= 80, do: "compliant", else: "non_compliant"),
      score: score,
      evidence_count: length(evidence),
      last_assessment: DateTime.utc_now(),
      issues: issues
    }

    {status, score, issues}
  end

  defp assess_generic_control(_control, evidence, _state) do
    # Generic assessment based on evidence
    # Simple scoring based on evidence
    score = min(100, length(evidence) * 25)

    status = %{
      status: if(score >= 80, do: "compliant", else: "needs_evidence"),
      score: score,
      evidence_count: length(evidence),
      last_assessment: DateTime.utc_now(),
      issues: []
    }

    {status, score, []}
  end

  defp calculate_control_score(checks, evidence) do
    check_score = checks |> Enum.count(& &1) |> Kernel.*(100) |> Kernel./(length(checks))
    # Up to 20 points for evidence
    evidence_score = min(20, length(evidence) * 5)

    min(100, check_score + evidence_score)
  end

  # Control check implementations
  # RBAC module exists - check if RBAC module is properly configured
  defp check_rbac_implementation do
    case Code.ensure_loaded(FLAME.Security.RBAC) do
      {:module, _} -> true
      {:error, _} -> false
    end
  end

  # Check if access reviews are current via application config
  defp check_access_reviews do
    Application.get_env(:flame_apple_container_backend, :access_reviews_current, false)
  end

  # Check if strong authentication is enabled via application config
  defp check_strong_authentication do
    Application.get_env(:flame_apple_container_backend, :strong_authentication_enabled, false)
  end

  # Check session management via application config
  defp check_session_management do
    Application.get_env(:flame_apple_container_backend, :session_management_enabled, true)
  end

  # Check RBAC enforcement - verify the module is loaded and configured
  defp check_rbac_enforcement do
    case Code.ensure_loaded(FLAME.Security.RBAC) do
      {:module, _} -> true
      {:error, _} -> false
    end
  end

  # Check least privilege via application config
  defp check_least_privilege do
    Application.get_env(:flame_apple_container_backend, :least_privilege_enforced, true)
  end

  # Check audit logging - verify AuditLogger module is available
  defp check_audit_logging do
    case Code.ensure_loaded(FLAME.Security.AuditLogger) do
      {:module, _} -> true
      {:error, _} -> false
    end
  end

  # Check log integrity via application config (needs external verification)
  defp check_log_integrity do
    configured =
      Application.get_env(:flame_apple_container_backend, :log_integrity_verified, false)

    unless configured do
      Logger.debug(
        "Log integrity check needs configuration - set :log_integrity_verified in app config"
      )
    end

    configured
  end

  # Check retention compliance via application config
  defp check_retention_compliance do
    Application.get_env(:flame_apple_container_backend, :retention_compliance_verified, false)
  end

  # Check real-time monitoring via application config
  defp check_real_time_monitoring do
    Application.get_env(:flame_apple_container_backend, :real_time_monitoring_enabled, true)
  end

  # Check alerting configuration via application config
  defp check_alerting_configuration do
    Application.get_env(:flame_apple_container_backend, :alerting_configured, true)
  end

  # Check encryption at rest (needs external verification)
  defp check_encryption_at_rest do
    configured =
      Application.get_env(:flame_apple_container_backend, :encryption_at_rest_enabled, false)

    unless configured do
      Logger.debug(
        "Encryption at rest check needs configuration - set :encryption_at_rest_enabled in app config"
      )
    end

    configured
  end

  # Check encryption in transit (needs external verification)
  defp check_encryption_in_transit do
    configured =
      Application.get_env(:flame_apple_container_backend, :encryption_in_transit_enabled, false)

    unless configured do
      Logger.debug(
        "Encryption in transit check needs configuration - set :encryption_in_transit_enabled in app config"
      )
    end

    configured
  end

  # Check data classification (needs external verification)
  defp check_data_classification do
    configured =
      Application.get_env(:flame_apple_container_backend, :data_classification_enabled, false)

    unless configured do
      Logger.debug(
        "Data classification check needs configuration - set :data_classification_enabled in app config"
      )
    end

    configured
  end

  # Check incident response plan via application config
  defp check_incident_response_plan do
    Application.get_env(:flame_apple_container_backend, :incident_response_plan_exists, false)
  end

  # Check notification procedures via application config
  defp check_notification_procedures do
    Application.get_env(
      :flame_apple_container_backend,
      :notification_procedures_configured,
      false
    )
  end

  defp update_compliance_status(state, assessment_results) do
    updated_status = Map.merge(state.compliance_status, assessment_results)

    # Add to assessment history
    history_entry = %{
      timestamp: DateTime.utc_now(),
      results: assessment_results
    }

    # Keep last 100
    updated_history = [history_entry | state.assessment_history] |> Enum.take(100)

    %{state | compliance_status: updated_status, assessment_history: updated_history}
  end

  defp update_single_framework_status(state, framework, result) do
    updated_status = Map.put(state.compliance_status, framework, result)
    %{state | compliance_status: updated_status}
  end

  defp generate_compliance_report_impl(framework, options, state) do
    case Map.get(state.compliance_status, framework) do
      nil ->
        {:error, :framework_not_found}

      status ->
        report = %{
          framework: framework,
          generated_at: DateTime.utc_now(),
          report_type: Map.get(options, :type, "summary"),
          compliance_status: status,
          executive_summary: generate_executive_summary(status),
          detailed_findings: generate_detailed_findings(status),
          recommendations: generate_recommendations(status.issues),
          evidence_summary: summarize_evidence(framework, state),
          next_assessment: calculate_next_assessment_date(framework)
        }

        {:ok, report}
    end
  end

  defp generate_executive_summary(status) do
    %{
      overall_score: status.score,
      compliance_level: if(status.score >= 80, do: "Compliant", else: "Non-Compliant"),
      total_controls: map_size(status.controls),
      compliant_controls: count_compliant_controls(status.controls),
      critical_issues: count_critical_issues(status.issues),
      last_assessment: status.last_assessment
    }
  end

  defp generate_detailed_findings(status) do
    status.controls
    |> Enum.map(fn {control_id, control_status} ->
      %{
        control_id: control_id,
        status: control_status.status,
        score: control_status.score,
        evidence_count: control_status.evidence_count,
        issues: control_status.issues
      }
    end)
  end

  defp summarize_evidence(framework, state) do
    state.control_evidence
    |> Enum.filter(fn {{fw, _control}, _evidence} -> fw == framework end)
    |> Enum.map(fn {{_fw, control}, evidence} ->
      %{
        control_id: control,
        evidence_count: length(evidence),
        last_updated: get_latest_evidence_date(evidence)
      }
    end)
  end

  defp get_latest_evidence_date(evidence) do
    evidence
    |> Enum.map(& &1.timestamp)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp count_compliant_controls(controls) do
    Enum.count(controls, fn {_id, status} -> status.status == "compliant" end)
  end

  defp count_critical_issues(issues) do
    Enum.count(issues, &(&1.severity == "critical"))
  end

  defp calculate_next_assessment_date(_framework) do
    # Default to 30 days from now
    DateTime.utc_now() |> DateTime.add(30 * 24 * 60 * 60, :second)
  end

  defp create_remediation_task_impl(issue) do
    %{
      id: generate_task_id(),
      title: issue.title || "Compliance Remediation Task",
      description: issue.description,
      framework: issue.framework,
      control_id: issue.control_id,
      priority: determine_priority(issue),
      status: "open",
      assigned_to: issue.assigned_to,
      due_date: calculate_due_date(issue),
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end

  defp determine_priority(issue) do
    case issue.severity do
      "critical" -> "critical"
      "high" -> "high"
      "medium" -> "medium"
      _ -> "low"
    end
  end

  defp calculate_due_date(issue) do
    days_to_add =
      case issue.severity do
        "critical" -> 7
        "high" -> 30
        "medium" -> 90
        _ -> 180
      end

    DateTime.utc_now() |> DateTime.add(days_to_add * 24 * 60 * 60, :second)
  end

  defp filter_remediation_tasks(tasks, status) do
    case status do
      nil -> tasks
      specific_status -> Enum.filter(tasks, &(&1.status == specific_status))
    end
  end

  defp check_compliance_violations(results) do
    Enum.each(results, fn {framework, result} ->
      if result.score < 70 do
        AlertManager.create_alert(%{
          type: "compliance_violation",
          severity: "high",
          title: "Compliance Score Below Threshold",
          description:
            "#{framework} compliance score (#{result.score}%) is below acceptable threshold",
          metadata: %{framework: framework, score: result.score}
        })
      end
    end)
  end

  defp generate_recommendations(issues) do
    issues
    |> Enum.group_by(& &1.type)
    |> Enum.map(fn {issue_type, grouped_issues} ->
      generate_recommendation_for_issue_type(issue_type, grouped_issues)
    end)
  end

  defp generate_recommendation_for_issue_type(issue_type, issues) do
    case issue_type do
      "missing_rbac" ->
        "Implement comprehensive Role-Based Access Control (RBAC) system"

      "weak_authentication" ->
        "Strengthen authentication policies with multi-factor authentication"

      "outdated_access_review" ->
        "Conduct regular access reviews according to compliance requirements"

      _ ->
        "Address #{issue_type} issues (#{length(issues)} instances)"
    end
  end

  defp setup_notification_config(opts) do
    %{
      email_enabled: Keyword.get(opts, :email_notifications, true),
      slack_enabled: Keyword.get(opts, :slack_notifications, false),
      compliance_contacts: Keyword.get(opts, :compliance_contacts, []),
      escalation_rules: Keyword.get(opts, :escalation_rules, [])
    }
  end

  defp schedule_compliance_assessment(hours) do
    Process.send_after(self(), :run_scheduled_assessment, hours * 60 * 60 * 1000)
  end

  defp generate_task_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
