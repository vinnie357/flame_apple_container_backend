defmodule FlameWeb.ApiController do
  @moduledoc """
  REST API controller for Apple Containers FLAME backend.

  Provides comprehensive REST endpoints for:
  - Cluster management and monitoring
  - Job submission and workflow orchestration
  - Container image lifecycle management
  - Alert management and configuration
  - Security and compliance monitoring
  - Performance metrics and analytics
  """

  use FlameWeb, :controller
  require Logger

  alias FLAME.{
    ClusterManager,
    JobManager,
    ImageManager,
    AlertManager,
    ResourceManager
  }

  # API Version
  @api_version "v1"

  ## Cluster Management Endpoints

  @doc """
  GET /api/v1/clusters
  List all registered clusters with their status and metrics.
  """
  def list_clusters(conn, params) do
    case ClusterManager.get_cluster_status() do
      clusters when is_list(clusters) ->
        filtered_clusters = apply_cluster_filters(clusters, params)

        response = %{
          clusters: Enum.map(filtered_clusters, &format_cluster_response/1),
          total_count: length(clusters),
          filtered_count: length(filtered_clusters),
          api_version: @api_version
        }

        conn
        |> put_status(:ok)
        |> json(response)

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Failed to retrieve clusters", reason: reason})
    end
  end

  @doc """
  GET /api/v1/clusters/:cluster_id
  Get detailed information about a specific cluster.
  """
  def get_cluster(conn, %{"cluster_id" => cluster_id}) do
    case ClusterManager.get_cluster_status() do
      clusters when is_list(clusters) ->
        case Enum.find(clusters, &(&1.id == cluster_id)) do
          nil ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Cluster not found", cluster_id: cluster_id})

          cluster ->
            response = format_detailed_cluster_response(cluster)

            conn
            |> put_status(:ok)
            |> json(response)
        end

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Failed to retrieve cluster", reason: reason})
    end
  end

  @doc """
  POST /api/v1/clusters
  Register a new cluster in the multi-cluster environment.
  """
  def create_cluster(conn, params) do
    case validate_cluster_params(params) do
      :ok ->
        cluster_config = build_cluster_config(params)

        case ClusterManager.register_cluster(params["id"], cluster_config) do
          {:ok, cluster_info} ->
            response = %{
              message: "Cluster registered successfully",
              cluster: format_cluster_response(cluster_info),
              api_version: @api_version
            }

            conn
            |> put_status(:created)
            |> json(response)

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to register cluster", reason: reason})
        end

      {:error, validation_errors} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Validation failed", details: validation_errors})
    end
  end

  @doc """
  DELETE /api/v1/clusters/:cluster_id
  Unregister a cluster from the multi-cluster environment.
  """
  def delete_cluster(conn, %{"cluster_id" => cluster_id}) do
    case ClusterManager.unregister_cluster(cluster_id) do
      :ok ->
        conn
        |> put_status(:no_content)
        |> json(%{message: "Cluster unregistered successfully"})

      {:error, :cluster_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Cluster not found", cluster_id: cluster_id})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to unregister cluster", reason: reason})
    end
  end

  @doc """
  POST /api/v1/clusters/:cluster_id/failover
  Trigger manual failover from one cluster to another.
  """
  def trigger_failover(conn, %{"cluster_id" => from_cluster, "target_cluster_id" => to_cluster}) do
    case ClusterManager.trigger_failover(from_cluster, to_cluster, "api_request") do
      :ok ->
        response = %{
          message: "Failover initiated successfully",
          from_cluster: from_cluster,
          to_cluster: to_cluster,
          initiated_at: System.system_time(:millisecond)
        }

        conn
        |> put_status(:accepted)
        |> json(response)

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failover failed", reason: reason})
    end
  end

  ## Job Management Endpoints

  @doc """
  GET /api/v1/jobs
  List jobs with optional filtering and pagination.
  """
  def list_jobs(conn, params) do
    filters = extract_job_filters(params)

    case JobManager.list_jobs(filters) do
      jobs when is_list(jobs) ->
        {paginated_jobs, pagination} = paginate_results(jobs, params)

        response = %{
          jobs: Enum.map(paginated_jobs, &format_job_response/1),
          pagination: pagination,
          filters_applied: filters,
          api_version: @api_version
        }

        conn
        |> put_status(:ok)
        |> json(response)

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Failed to retrieve jobs", reason: reason})
    end
  end

  @doc """
  GET /api/v1/jobs/:job_id
  Get detailed information about a specific job.
  """
  def get_job(conn, %{"job_id" => job_id}) do
    case JobManager.get_job_status(job_id) do
      {:ok, job_status} ->
        response = format_detailed_job_response(job_status)

        conn
        |> put_status(:ok)
        |> json(response)

      {:error, :job_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found", job_id: job_id})

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Failed to retrieve job", reason: reason})
    end
  end

  @doc """
  POST /api/v1/jobs
  Submit a new job for execution.
  """
  def create_job(conn, params) do
    case validate_job_params(params) do
      :ok ->
        job_spec = build_job_spec(params)
        options = extract_job_options(params)

        case JobManager.submit_job(job_spec, options) do
          {:ok, job_id} ->
            response = %{
              message: "Job submitted successfully",
              job_id: job_id,
              submitted_at: System.system_time(:millisecond),
              api_version: @api_version
            }

            conn
            |> put_status(:created)
            |> json(response)

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to submit job", reason: reason})
        end

      {:error, validation_errors} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Validation failed", details: validation_errors})
    end
  end

  @doc """
  DELETE /api/v1/jobs/:job_id
  Cancel a pending or running job.
  """
  def cancel_job(conn, %{"job_id" => job_id}) do
    reason = get_in(conn.params, ["reason"]) || "cancelled_via_api"

    case JobManager.cancel_job(job_id, reason) do
      :ok ->
        response = %{
          message: "Job cancelled successfully",
          job_id: job_id,
          cancelled_at: System.system_time(:millisecond)
        }

        conn
        |> put_status(:ok)
        |> json(response)

      {:error, :job_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found", job_id: job_id})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to cancel job", reason: reason})
    end
  end

  @doc """
  GET /api/v1/workflows
  List workflows with their execution status.
  """
  def list_workflows(conn, _params) do
    # This would integrate with JobManager's workflow functionality
    # Placeholder
    workflows = []

    response = %{
      workflows: workflows,
      total_count: length(workflows),
      api_version: @api_version
    }

    conn
    |> put_status(:ok)
    |> json(response)
  end

  @doc """
  POST /api/v1/workflows
  Submit a new workflow for execution.
  """
  def create_workflow(conn, params) do
    case validate_workflow_params(params) do
      :ok ->
        workflow_spec = build_workflow_spec(params)
        options = extract_workflow_options(params)

        case JobManager.submit_workflow(workflow_spec, options) do
          {:ok, workflow_id} ->
            response = %{
              message: "Workflow submitted successfully",
              workflow_id: workflow_id,
              submitted_at: System.system_time(:millisecond),
              api_version: @api_version
            }

            conn
            |> put_status(:created)
            |> json(response)

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to submit workflow", reason: reason})
        end

      {:error, validation_errors} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Validation failed", details: validation_errors})
    end
  end

  ## Image Management Endpoints

  @doc """
  GET /api/v1/images
  List container images with their status and metadata.
  """
  def list_images(conn, params) do
    filters = extract_image_filters(params)

    case ImageManager.list_images(filters) do
      images when is_list(images) ->
        {paginated_images, pagination} = paginate_results(images, params)

        response = %{
          images: Enum.map(paginated_images, &format_image_response/1),
          pagination: pagination,
          filters_applied: filters,
          api_version: @api_version
        }

        conn
        |> put_status(:ok)
        |> json(response)

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Failed to retrieve images", reason: reason})
    end
  end

  @doc """
  GET /api/v1/images/:image_id
  Get detailed information about a specific image.
  """
  def get_image(conn, %{"image_id" => image_id}) do
    case ImageManager.get_image_info(image_id) do
      {:ok, image_info} ->
        response = format_detailed_image_response(image_info)

        conn
        |> put_status(:ok)
        |> json(response)

      {:error, :image_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Image not found", image_id: image_id})

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Failed to retrieve image", reason: reason})
    end
  end

  @doc """
  POST /api/v1/images/build
  Trigger a new image build.
  """
  def build_image(conn, params) do
    case validate_build_params(params) do
      :ok ->
        build_spec = build_image_spec(params)

        case ImageManager.build_image(build_spec) do
          {:ok, build_id} ->
            response = %{
              message: "Image build started successfully",
              build_id: build_id,
              started_at: System.system_time(:millisecond),
              api_version: @api_version
            }

            conn
            |> put_status(:accepted)
            |> json(response)

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to start image build", reason: reason})
        end

      {:error, validation_errors} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Validation failed", details: validation_errors})
    end
  end

  @doc """
  POST /api/v1/images/:image_id/deploy
  Deploy an image to production using blue-green deployment.
  """
  def deploy_image(conn, %{"image_id" => image_id} = params) do
    deployment_config = extract_deployment_config(params)

    case ImageManager.deploy_image(image_id, deployment_config) do
      {:ok, deployment_id} ->
        response = %{
          message: "Image deployment started successfully",
          deployment_id: deployment_id,
          image_id: image_id,
          started_at: System.system_time(:millisecond),
          api_version: @api_version
        }

        conn
        |> put_status(:accepted)
        |> json(response)

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to deploy image", reason: reason})
    end
  end

  @doc """
  POST /api/v1/images/:image_id/scan
  Trigger security scan for an image.
  """
  def scan_image(conn, %{"image_id" => image_id}) do
    case ImageManager.scan_image(image_id) do
      {:ok, :scan_started} ->
        response = %{
          message: "Security scan started successfully",
          image_id: image_id,
          started_at: System.system_time(:millisecond),
          api_version: @api_version
        }

        conn
        |> put_status(:accepted)
        |> json(response)

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to start security scan", reason: reason})
    end
  end

  ## Alert Management Endpoints

  @doc """
  GET /api/v1/alerts
  List active alerts with optional filtering.
  """
  def list_alerts(conn, params) do
    case AlertManager.get_active_alerts() do
      alerts when is_list(alerts) ->
        filtered_alerts = apply_alert_filters(alerts, params)
        {paginated_alerts, pagination} = paginate_results(filtered_alerts, params)

        response = %{
          alerts: Enum.map(paginated_alerts, &format_alert_response/1),
          pagination: pagination,
          summary: calculate_alert_summary(alerts),
          api_version: @api_version
        }

        conn
        |> put_status(:ok)
        |> json(response)

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Failed to retrieve alerts", reason: reason})
    end
  end

  @doc """
  POST /api/v1/alerts/:alert_id/acknowledge
  Acknowledge an active alert.
  """
  def acknowledge_alert(conn, %{"alert_id" => alert_id} = params) do
    user_id = get_in(params, ["user_id"]) || "api_user"
    notes = get_in(params, ["notes"]) || ""

    case AlertManager.acknowledge_alert(alert_id, user_id, notes) do
      :ok ->
        response = %{
          message: "Alert acknowledged successfully",
          alert_id: alert_id,
          acknowledged_by: user_id,
          acknowledged_at: System.system_time(:millisecond)
        }

        conn
        |> put_status(:ok)
        |> json(response)

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to acknowledge alert", reason: reason})
    end
  end

  @doc """
  POST /api/v1/alerts/:alert_id/resolve
  Resolve an active alert.
  """
  def resolve_alert(conn, %{"alert_id" => alert_id} = params) do
    user_id = get_in(params, ["user_id"]) || "api_user"
    resolution_notes = get_in(params, ["resolution_notes"]) || ""

    case AlertManager.resolve_alert(alert_id, user_id, resolution_notes) do
      :ok ->
        response = %{
          message: "Alert resolved successfully",
          alert_id: alert_id,
          resolved_by: user_id,
          resolved_at: System.system_time(:millisecond)
        }

        conn
        |> put_status(:ok)
        |> json(response)

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to resolve alert", reason: reason})
    end
  end

  ## Metrics and Analytics Endpoints

  @doc """
  GET /api/v1/metrics/overview
  Get high-level system metrics and health indicators.
  """
  def metrics_overview(conn, _params) do
    try do
      cluster_metrics = get_cluster_metrics()
      job_metrics = get_job_metrics()
      image_metrics = get_image_metrics()
      resource_metrics = get_resource_metrics()

      response = %{
        timestamp: System.system_time(:millisecond),
        clusters: cluster_metrics,
        jobs: job_metrics,
        images: image_metrics,
        resources: resource_metrics,
        api_version: @api_version
      }

      conn
      |> put_status(:ok)
      |> json(response)
    rescue
      error ->
        Logger.error("Failed to retrieve metrics overview: #{inspect(error)}")

        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Failed to retrieve metrics", reason: "internal_error"})
    end
  end

  @doc """
  GET /api/v1/metrics/performance
  Get detailed performance metrics and time series data.
  """
  def performance_metrics(conn, params) do
    time_range = extract_time_range(params)
    metrics_types = extract_metrics_types(params)

    try do
      performance_data = get_performance_metrics(time_range, metrics_types)

      response = %{
        time_range: time_range,
        metrics: performance_data,
        api_version: @api_version
      }

      conn
      |> put_status(:ok)
      |> json(response)
    rescue
      error ->
        Logger.error("Failed to retrieve performance metrics: #{inspect(error)}")

        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Failed to retrieve performance metrics", reason: "internal_error"})
    end
  end

  @doc """
  GET /api/v1/health
  System health check endpoint.
  """
  def health_check(conn, _params) do
    health_status = perform_health_check()

    status_code =
      if health_status.overall == :healthy do
        :ok
      else
        :service_unavailable
      end

    conn
    |> put_status(status_code)
    |> json(health_status)
  end

  ## Private Helper Functions

  # Validation functions

  defp validate_cluster_params(params) do
    required_fields = ["id", "endpoints"]
    errors = []

    # Check required fields
    errors =
      Enum.reduce(required_fields, errors, fn field, acc ->
        if Map.has_key?(params, field) do
          acc
        else
          ["Missing required field: #{field}" | acc]
        end
      end)

    # Validate endpoints
    errors =
      if Map.has_key?(params, "endpoints") and is_list(params["endpoints"]) do
        errors
      else
        ["endpoints must be a list" | errors]
      end

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp validate_job_params(params) do
    required_fields = ["name", "function"]
    errors = []

    errors =
      Enum.reduce(required_fields, errors, fn field, acc ->
        if Map.has_key?(params, field) do
          acc
        else
          ["Missing required field: #{field}" | acc]
        end
      end)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp validate_workflow_params(params) do
    required_fields = ["name", "steps"]
    errors = []

    errors =
      Enum.reduce(required_fields, errors, fn field, acc ->
        if Map.has_key?(params, field) do
          acc
        else
          ["Missing required field: #{field}" | acc]
        end
      end)

    # Validate steps structure
    errors =
      if Map.has_key?(params, "steps") and is_list(params["steps"]) do
        errors
      else
        ["steps must be a list" | errors]
      end

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp validate_build_params(params) do
    required_fields = ["name", "source"]
    errors = []

    errors =
      Enum.reduce(required_fields, errors, fn field, acc ->
        if Map.has_key?(params, field) do
          acc
        else
          ["Missing required field: #{field}" | acc]
        end
      end)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  # Builder functions

  defp build_cluster_config(params) do
    %{
      endpoints: params["endpoints"],
      region: params["region"],
      zone: params["zone"],
      capabilities: params["capabilities"] || [],
      credentials: params["credentials"]
    }
  end

  defp build_job_spec(params) do
    %{
      name: params["name"],
      function: parse_function_spec(params["function"]),
      parameters: params["parameters"] || %{},
      requirements: params["requirements"] || %{}
    }
  end

  defp build_workflow_spec(params) do
    %{
      name: params["name"],
      description: params["description"],
      steps: Enum.map(params["steps"], &parse_workflow_step/1)
    }
  end

  defp build_image_spec(params) do
    %{
      name: params["name"],
      version: params["version"],
      source: parse_source_spec(params["source"]),
      metadata: params["metadata"] || %{}
    }
  end

  # Parser functions

  defp parse_function_spec(function_spec) when is_map(function_spec) do
    {
      String.to_existing_atom(function_spec["module"]),
      String.to_existing_atom(function_spec["function"]),
      function_spec["args"] || []
    }
  rescue
    _ -> function_spec
  end

  defp parse_function_spec(function_spec), do: function_spec

  defp parse_workflow_step(step) do
    %{
      id: step["id"],
      name: step["name"],
      job_spec: build_job_spec(step["job_spec"]),
      depends_on: step["depends_on"] || [],
      condition: step["condition"]
    }
  end

  defp parse_source_spec(source) do
    %{
      type: String.to_existing_atom(source["type"]),
      url: source["url"],
      branch: source["branch"],
      path: source["path"]
    }
  end

  # Filter and extraction functions

  defp apply_cluster_filters(clusters, params) do
    clusters
    |> filter_by_status(params["status"])
    |> filter_by_region(params["region"])
  end

  defp extract_job_filters(params) do
    %{}
    |> put_if_present(:state, params["state"])
    |> put_if_present(:priority, params["priority"])
    |> put_if_present(:queue, params["queue"])
  end

  defp extract_image_filters(params) do
    %{}
    |> put_if_present(:state, params["state"])
    |> put_if_present(:name, params["name"])
  end

  defp apply_alert_filters(alerts, params) do
    alerts
    |> filter_by_severity(params["severity"])
    |> filter_by_status(params["status"])
  end

  defp extract_job_options(params) do
    %{}
    |> put_if_present(:priority, params["priority"])
    |> put_if_present(:timeout_ms, params["timeout_ms"])
    |> put_if_present(:max_retries, params["max_retries"])
  end

  defp extract_workflow_options(params) do
    %{}
    |> put_if_present(:metadata, params["metadata"])
  end

  defp extract_deployment_config(params) do
    %{}
    |> put_if_present(:strategy, params["strategy"])
    |> put_if_present(:rollout_percentage, params["rollout_percentage"])
  end

  defp extract_time_range(params) do
    %{
      start_time: params["start_time"],
      end_time: params["end_time"],
      duration: params["duration"] || "1h"
    }
  end

  defp extract_metrics_types(params) do
    case params["metrics"] do
      nil ->
        [:cpu, :memory, :containers, :jobs]

      types when is_list(types) ->
        Enum.map(types, &String.to_existing_atom/1)

      types when is_binary(types) ->
        String.split(types, ",") |> Enum.map(&String.to_existing_atom/1)
    end
  end

  # Pagination

  defp paginate_results(items, params) do
    page = String.to_integer(params["page"] || "1")
    per_page = min(String.to_integer(params["per_page"] || "50"), 1000)

    total_count = length(items)
    total_pages = ceil(total_count / per_page)
    offset = (page - 1) * per_page

    paginated_items = items |> Enum.drop(offset) |> Enum.take(per_page)

    pagination = %{
      current_page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages,
      has_next_page: page < total_pages,
      has_prev_page: page > 1
    }

    {paginated_items, pagination}
  end

  # Response formatting functions

  defp format_cluster_response(cluster) do
    %{
      id: cluster.id,
      type: cluster.type,
      status: cluster.status,
      region: cluster.region,
      zone: cluster.zone,
      is_primary: cluster.is_primary,
      resources: %{
        total_memory_gb: cluster.resources.total_memory_gb,
        available_memory_gb: cluster.resources.available_memory_gb,
        total_cpu_cores: cluster.resources.total_cpu_cores,
        available_cpu_cores: cluster.resources.available_cpu_cores,
        max_containers: cluster.resources.max_containers,
        active_containers: cluster.resources.active_containers
      },
      health: %{
        status: cluster.health_check.status,
        last_check: cluster.health_check.last_check
      },
      last_seen: cluster.last_seen
    }
  end

  defp format_detailed_cluster_response(cluster) do
    base_response = format_cluster_response(cluster)

    Map.merge(base_response, %{
      endpoints: cluster.endpoints,
      capabilities: cluster.capabilities,
      version: cluster.version,
      priority: cluster.priority
    })
  end

  defp format_job_response(job) do
    %{
      id: job.id,
      name: job.name,
      state: job.state,
      priority: job.priority,
      queue: job.queue,
      progress: job.progress,
      created_at: job.created_at,
      started_at: job.started_at,
      completed_at: job.completed_at,
      duration_ms: calculate_job_duration(job)
    }
  end

  defp format_detailed_job_response(job) do
    base_response = format_job_response(job)

    Map.merge(base_response, %{
      parameters: job.parameters,
      requirements: job.requirements,
      retry_count: job.retry_count,
      max_retries: job.max_retries,
      error_message: job.error_message,
      result: job.result,
      resource_usage: job.resource_usage,
      metadata: job.metadata
    })
  end

  defp format_image_response(image) do
    %{
      id: image.id,
      name: image.name,
      version: image.version,
      state: image.state,
      size_bytes: image.size_bytes,
      created_at: image.created_at,
      updated_at: image.updated_at,
      vulnerabilities: format_vulnerabilities(image.scan_results)
    }
  end

  defp format_detailed_image_response(image) do
    base_response = format_image_response(image)

    Map.merge(base_response, %{
      build_spec: image.build_spec,
      layers: image.layers,
      deployment_history: image.deployment_history,
      metadata: image.metadata
    })
  end

  defp format_alert_response(alert) do
    %{
      id: alert.id,
      name: alert.name,
      severity: alert.severity,
      status: alert.status,
      description: alert.description,
      triggered_at: alert.triggered_at,
      acknowledged_at: alert.acknowledged_at,
      resolved_at: alert.resolved_at,
      runbook_url: alert.runbook_url,
      tags: alert.tags
    }
  end

  defp format_vulnerabilities(scan_results) do
    case scan_results do
      {:ok, results} -> results.vulnerabilities
      _ -> %{critical: 0, high: 0, medium: 0, low: 0}
    end
  end

  # Metrics gathering functions

  defp get_cluster_metrics do
    case ClusterManager.get_aggregated_metrics() do
      metrics when is_map(metrics) -> metrics
      _ -> %{}
    end
  end

  defp get_job_metrics do
    case JobManager.get_job_metrics() do
      metrics when is_map(metrics) -> metrics
      _ -> %{}
    end
  end

  defp get_image_metrics do
    case ImageManager.get_image_metrics() do
      metrics when is_map(metrics) -> metrics
      _ -> %{}
    end
  end

  defp get_resource_metrics do
    case GenServer.call(ResourceManager, :get_resource_status, 5000) do
      status when is_map(status) -> status
      _ -> %{}
    end
  catch
    _ -> %{}
  end

  defp get_performance_metrics(_time_range, _metrics_types) do
    # This would implement actual time series data retrieval
    %{
      cpu_utilization: [],
      memory_utilization: [],
      job_throughput: [],
      error_rates: []
    }
  end

  defp perform_health_check do
    components = [
      {:cluster_manager, check_component_health(ClusterManager)},
      {:job_manager, check_component_health(JobManager)},
      {:image_manager, check_component_health(ImageManager)},
      {:alert_manager, check_component_health(AlertManager)},
      {:resource_manager, check_component_health(ResourceManager)}
    ]

    overall_health =
      if Enum.all?(components, fn {_, status} -> status == :healthy end) do
        :healthy
      else
        :degraded
      end

    %{
      overall: overall_health,
      components: Enum.into(components, %{}),
      timestamp: System.system_time(:millisecond),
      api_version: @api_version
    }
  end

  defp check_component_health(module) do
    case GenServer.call(module, :health_check, 5000) do
      :ok -> :healthy
      {:ok, _} -> :healthy
      _ -> :unhealthy
    end
  catch
    _ -> :unhealthy
  end

  # Utility functions

  defp filter_by_status(items, nil), do: items

  defp filter_by_status(items, status),
    do: Enum.filter(items, &(&1.status == String.to_existing_atom(status)))

  defp filter_by_region(items, nil), do: items
  defp filter_by_region(items, region), do: Enum.filter(items, &(&1.region == region))

  defp filter_by_severity(items, nil), do: items

  defp filter_by_severity(items, severity),
    do: Enum.filter(items, &(&1.severity == String.to_integer(severity)))

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

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

  defp calculate_alert_summary(alerts) do
    active_alerts = Enum.filter(alerts, &(&1.status == :active))

    %{
      total_active: length(active_alerts),
      by_severity: %{
        critical: Enum.count(active_alerts, &(&1.severity == 1)),
        high: Enum.count(active_alerts, &(&1.severity == 2)),
        medium: Enum.count(active_alerts, &(&1.severity == 3)),
        low: Enum.count(active_alerts, &(&1.severity in [4, 5]))
      }
    }
  end
end
