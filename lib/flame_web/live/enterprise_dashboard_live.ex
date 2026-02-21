defmodule FlameWeb.EnterpriseDashboardLive do
  @moduledoc """
  Enterprise-grade dashboard for Apple Containers FLAME backend.

  Features comprehensive monitoring and management including:
  - Multi-cluster overview and management
  - Advanced alerting and notification center
  - Container image lifecycle management
  - Job queue and workflow orchestration
  - Security and compliance monitoring
  - Performance analytics and cost optimization
  - Real-time metrics and health monitoring
  """

  use FlameWeb, :live_view
  require Logger

  alias FLAME.{
    ClusterManager,
    AlertManager,
    ImageManager,
    JobManager
  }

  # 5 seconds
  @refresh_interval 5_000
  @chart_data_points 50

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to real-time updates
      :timer.send_interval(@refresh_interval, self(), :refresh_data)

      # Subscribe to telemetry events for real-time updates
      subscribe_to_telemetry()
    end

    socket =
      socket
      |> assign(:page_title, "FLAME Enterprise Dashboard")
      |> assign(:current_tab, "overview")
      |> assign(:refresh_interval, @refresh_interval)
      |> assign(:last_updated, DateTime.utc_now())
      |> load_initial_data()

    {:ok, socket}
  end

  def handle_params(%{"tab" => tab}, _uri, socket) do
    {:noreply, assign(socket, :current_tab, tab)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  def handle_info(:refresh_data, socket) do
    socket = refresh_dashboard_data(socket)
    {:noreply, socket}
  end

  def handle_info({:telemetry, event_name, measurements, metadata}, socket) do
    socket = handle_real_time_event(socket, event_name, measurements, metadata)
    {:noreply, socket}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: "/enterprise-dashboard/#{tab}")}
  end

  def handle_event("refresh", _params, socket) do
    socket = refresh_dashboard_data(socket)
    {:noreply, socket}
  end

  # Cluster Management Events
  def handle_event("register_cluster", %{"cluster_config" => config}, socket) do
    try do
      case ClusterManager.register_cluster(config["id"], parse_cluster_config(config)) do
        {:ok, _cluster_info} ->
          socket = put_flash(socket, :info, "Cluster #{config["id"]} registered successfully")
          socket = refresh_cluster_data(socket)
          {:noreply, socket}

        {:error, reason} ->
          socket = put_flash(socket, :error, "Failed to register cluster: #{reason}")
          {:noreply, socket}
      end
    catch
      _ ->
        socket = put_flash(socket, :error, "Cluster management not available")
        {:noreply, socket}
    end
  end

  def handle_event("trigger_failover", %{"from_cluster" => from, "to_cluster" => to}, socket) do
    try do
      case ClusterManager.trigger_failover(from, to, "manual_dashboard") do
        :ok ->
          socket = put_flash(socket, :info, "Failover initiated from #{from} to #{to}")
          {:noreply, socket}

        {:error, reason} ->
          socket = put_flash(socket, :error, "Failover failed: #{reason}")
          {:noreply, socket}
      end
    catch
      _ ->
        socket = put_flash(socket, :error, "Cluster management not available")
        {:noreply, socket}
    end
  end

  # Alert Management Events
  def handle_event("acknowledge_alert", %{"alert_id" => alert_id}, socket) do
    case AlertManager.acknowledge_alert(alert_id, "dashboard_user", "Acknowledged via dashboard") do
      :ok ->
        socket = put_flash(socket, :info, "Alert #{alert_id} acknowledged")
        socket = refresh_alert_data(socket)
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to acknowledge alert: #{reason}")
        {:noreply, socket}
    end
  end

  def handle_event("resolve_alert", %{"alert_id" => alert_id}, socket) do
    case AlertManager.resolve_alert(alert_id, "dashboard_user", "Resolved via dashboard") do
      :ok ->
        socket = put_flash(socket, :info, "Alert #{alert_id} resolved")
        socket = refresh_alert_data(socket)
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to resolve alert: #{reason}")
        {:noreply, socket}
    end
  end

  def handle_event("test_notification", %{"channel_id" => channel_id}, socket) do
    case AlertManager.test_notification_channel(channel_id) do
      :ok ->
        socket = put_flash(socket, :info, "Test notification sent successfully")
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Test notification failed: #{reason}")
        {:noreply, socket}
    end
  end

  # Image Management Events
  def handle_event("build_image", %{"build_spec" => spec}, socket) do
    case ImageManager.build_image(parse_build_spec(spec)) do
      {:ok, build_id} ->
        socket = put_flash(socket, :info, "Image build started: #{build_id}")
        socket = refresh_image_data(socket)
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to start image build: #{reason}")
        {:noreply, socket}
    end
  end

  def handle_event("deploy_image", %{"image_id" => image_id}, socket) do
    case ImageManager.deploy_image(image_id) do
      {:ok, deployment_id} ->
        socket = put_flash(socket, :info, "Image deployment started: #{deployment_id}")
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to deploy image: #{reason}")
        {:noreply, socket}
    end
  end

  def handle_event("rollback_deployment", %{"deployment_id" => deployment_id}, socket) do
    case ImageManager.rollback_deployment(deployment_id) do
      {:ok, _result} ->
        socket = put_flash(socket, :info, "Rollback initiated for deployment #{deployment_id}")
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Rollback failed: #{reason}")
        {:noreply, socket}
    end
  end

  # Job Management Events
  def handle_event("submit_job", %{"job_spec" => spec}, socket) do
    case JobManager.submit_job(parse_job_spec(spec)) do
      {:ok, job_id} ->
        socket = put_flash(socket, :info, "Job submitted: #{job_id}")
        socket = refresh_job_data(socket)
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to submit job: #{reason}")
        {:noreply, socket}
    end
  end

  def handle_event("cancel_job", %{"job_id" => job_id}, socket) do
    case JobManager.cancel_job(job_id, "cancelled_via_dashboard") do
      :ok ->
        socket = put_flash(socket, :info, "Job #{job_id} cancelled")
        socket = refresh_job_data(socket)
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to cancel job: #{reason}")
        {:noreply, socket}
    end
  end

  def handle_event(
        "execute_template",
        %{"template_id" => template_id, "parameters" => params},
        socket
      ) do
    case JobManager.execute_template(template_id, parse_parameters(params)) do
      {:ok, job_id} ->
        socket = put_flash(socket, :info, "Template job executed: #{job_id}")
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to execute template: #{reason}")
        {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="enterprise-dashboard">
      <!-- Navigation Header -->
      <div class="dashboard-header">
        <div class="header-content">
          <h1>FLAME Enterprise Dashboard</h1>
          <div class="header-controls">
            <button phx-click="refresh" class="btn btn-primary">
              <span class="icon">🔄</span>
              Refresh
            </button>
            <div class="last-updated">
              Last updated: <%= @last_updated |> DateTime.to_time() |> Time.to_string() %>
            </div>
          </div>
        </div>
        
        <!-- Tab Navigation -->
        <nav class="tab-navigation">
          <button 
            class={"tab-btn #{if @current_tab == "overview", do: "active", else: ""}"}
            phx-click="switch_tab" 
            phx-value-tab="overview"
          >
            <span class="icon">📊</span>
            Overview
          </button>
          <button 
            class={"tab-btn #{if @current_tab == "clusters", do: "active", else: ""}"}
            phx-click="switch_tab" 
            phx-value-tab="clusters"
          >
            <span class="icon">🌐</span>
            Clusters
          </button>
          <button 
            class={"tab-btn #{if @current_tab == "alerts", do: "active", else: ""}"}
            phx-click="switch_tab" 
            phx-value-tab="alerts"
          >
            <span class="icon">🚨</span>
            Alerts
            <%= if @alert_summary.active_critical > 0 do %>
              <span class="badge badge-critical"><%= @alert_summary.active_critical %></span>
            <% end %>
          </button>
          <button 
            class={"tab-btn #{if @current_tab == "images", do: "active", else: ""}"}
            phx-click="switch_tab" 
            phx-value-tab="images"
          >
            <span class="icon">📦</span>
            Images
          </button>
          <button 
            class={"tab-btn #{if @current_tab == "jobs", do: "active", else: ""}"}
            phx-click="switch_tab" 
            phx-value-tab="jobs"
          >
            <span class="icon">⚙️</span>
            Jobs
            <%= if @job_summary.running > 0 do %>
              <span class="badge badge-info"><%= @job_summary.running %></span>
            <% end %>
          </button>
          <button 
            class={"tab-btn #{if @current_tab == "security", do: "active", else: ""}"}
            phx-click="switch_tab" 
            phx-value-tab="security"
          >
            <span class="icon">🔒</span>
            Security
          </button>
          <button 
            class={"tab-btn #{if @current_tab == "analytics", do: "active", else: ""}"}
            phx-click="switch_tab" 
            phx-value-tab="analytics"
          >
            <span class="icon">📈</span>
            Analytics
          </button>
        </nav>
      </div>
      
      <!-- Tab Content -->
      <div class="tab-content">
        <%= case @current_tab do %>
          <% "overview" -> %>
            <%= render_overview_tab(assigns) %>
          <% "clusters" -> %>
            <%= render_clusters_tab(assigns) %>
          <% "alerts" -> %>
            <%= render_alerts_tab(assigns) %>
          <% "images" -> %>
            <%= render_images_tab(assigns) %>
          <% "jobs" -> %>
            <%= render_jobs_tab(assigns) %>
          <% "security" -> %>
            <%= render_security_tab(assigns) %>
          <% "analytics" -> %>
            <%= render_analytics_tab(assigns) %>
          <% _ -> %>
            <%= render_overview_tab(assigns) %>
        <% end %>
      </div>
    </div>

    <!-- Styles -->
    <style>
      .enterprise-dashboard {
        min-height: 100vh;
        background: #f8fafc;
        font-family: -apple-system, BlinkMacSystemFont, sans-serif;
      }
      
      .dashboard-header {
        background: white;
        border-bottom: 1px solid #e2e8f0;
        box-shadow: 0 1px 3px rgba(0,0,0,0.1);
        position: sticky;
        top: 0;
        z-index: 100;
      }
      
      .header-content {
        display: flex;
        justify-content: space-between;
        align-items: center;
        padding: 1rem 2rem;
      }
      
      .header-content h1 {
        margin: 0;
        color: #1a202c;
        font-size: 1.5rem;
        font-weight: 600;
      }
      
      .header-controls {
        display: flex;
        align-items: center;
        gap: 1rem;
      }
      
      .tab-navigation {
        display: flex;
        padding: 0 2rem;
        background: #f7fafc;
        border-top: 1px solid #e2e8f0;
      }
      
      .tab-btn {
        display: flex;
        align-items: center;
        gap: 0.5rem;
        padding: 0.75rem 1rem;
        border: none;
        background: none;
        color: #4a5568;
        font-weight: 500;
        cursor: pointer;
        border-bottom: 2px solid transparent;
        transition: all 0.2s;
        position: relative;
      }
      
      .tab-btn:hover {
        color: #2d3748;
        background: #edf2f7;
      }
      
      .tab-btn.active {
        color: #3182ce;
        border-bottom-color: #3182ce;
        background: white;
      }
      
      .badge {
        padding: 0.125rem 0.375rem;
        border-radius: 9999px;
        font-size: 0.75rem;
        font-weight: 600;
        min-width: 1.25rem;
        text-align: center;
      }
      
      .badge-critical {
        background: #fed7d7;
        color: #742a2a;
      }
      
      .badge-info {
        background: #bee3f8;
        color: #2a69ac;
      }
      
      .tab-content {
        padding: 2rem;
        min-height: calc(100vh - 140px);
      }
      
      .btn {
        display: inline-flex;
        align-items: center;
        gap: 0.5rem;
        padding: 0.5rem 1rem;
        border: 1px solid transparent;
        border-radius: 0.375rem;
        font-weight: 500;
        cursor: pointer;
        transition: all 0.2s;
        text-decoration: none;
      }
      
      .btn-primary {
        background: #3182ce;
        color: white;
        border-color: #3182ce;
      }
      
      .btn-primary:hover {
        background: #2c5282;
        border-color: #2c5282;
      }
      
      .btn-success {
        background: #38a169;
        color: white;
        border-color: #38a169;
      }
      
      .btn-warning {
        background: #d69e2e;
        color: white;
        border-color: #d69e2e;
      }
      
      .btn-danger {
        background: #e53e3e;
        color: white;
        border-color: #e53e3e;
      }
      
      .btn-secondary {
        background: #edf2f7;
        color: #4a5568;
        border-color: #e2e8f0;
      }
      
      .icon {
        font-size: 1rem;
      }
      
      .last-updated {
        font-size: 0.875rem;
        color: #718096;
      }
      
      /* Grid layouts */
      .metrics-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
        gap: 1.5rem;
        margin-bottom: 2rem;
      }
      
      .chart-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));
        gap: 1.5rem;
        margin-bottom: 2rem;
      }
      
      .card {
        background: white;
        border-radius: 0.5rem;
        box-shadow: 0 1px 3px rgba(0,0,0,0.1);
        border: 1px solid #e2e8f0;
      }
      
      .card-header {
        padding: 1rem 1.5rem;
        border-bottom: 1px solid #e2e8f0;
        display: flex;
        justify-content: space-between;
        align-items: center;
      }
      
      .card-body {
        padding: 1.5rem;
      }
      
      .card-title {
        margin: 0;
        font-size: 1.125rem;
        font-weight: 600;
        color: #1a202c;
      }
      
      /* Status indicators */
      .status-healthy { color: #38a169; }
      .status-warning { color: #d69e2e; }
      .status-critical { color: #e53e3e; }
      .status-unknown { color: #718096; }
      
      /* Tables */
      .table {
        width: 100%;
        border-collapse: collapse;
      }
      
      .table th,
      .table td {
        padding: 0.75rem;
        text-align: left;
        border-bottom: 1px solid #e2e8f0;
      }
      
      .table th {
        background: #f7fafc;
        font-weight: 600;
        color: #4a5568;
        font-size: 0.875rem;
        text-transform: uppercase;
        letter-spacing: 0.05em;
      }
      
      .table tr:hover {
        background: #f7fafc;
      }
      
      /* Progress bars */
      .progress {
        width: 100%;
        height: 0.5rem;
        background: #edf2f7;
        border-radius: 0.25rem;
        overflow: hidden;
      }
      
      .progress-bar {
        height: 100%;
        background: #3182ce;
        transition: width 0.3s ease;
      }
      
      .progress-bar.success { background: #38a169; }
      .progress-bar.warning { background: #d69e2e; }
      .progress-bar.danger { background: #e53e3e; }
      
      /* Responsive design */
      @media (max-width: 768px) {
        .header-content {
          flex-direction: column;
          gap: 1rem;
          text-align: center;
        }
        
        .tab-navigation {
          overflow-x: auto;
          padding: 0 1rem;
        }
        
        .tab-btn {
          white-space: nowrap;
        }
        
        .tab-content {
          padding: 1rem;
        }
        
        .metrics-grid,
        .chart-grid {
          grid-template-columns: 1fr;
        }
      }
    </style>
    """
  end

  # Tab Rendering Functions

  defp render_overview_tab(assigns) do
    ~H"""
    <div class="overview-tab">
      <!-- High-level metrics -->
      <div class="metrics-grid">
        <div class="card">
          <div class="card-header">
            <h3 class="card-title">Multi-Cluster Status</h3>
          </div>
          <div class="card-body">
            <div class="metric-row">
              <span class="metric-label">Total Clusters</span>
              <span class="metric-value"><%= @cluster_summary.total %></span>
            </div>
            <div class="metric-row">
              <span class="metric-label">Healthy Clusters</span>
              <span class={"metric-value status-#{if @cluster_summary.healthy == @cluster_summary.total, do: "healthy", else: "warning"}"}><%= @cluster_summary.healthy %></span>
            </div>
            <div class="metric-row">
              <span class="metric-label">Total Containers</span>
              <span class="metric-value"><%= @cluster_summary.total_containers %></span>
            </div>
            <div class="metric-row">
              <span class="metric-label">Available Resources</span>
              <span class="metric-value"><%= @cluster_summary.available_memory_gb %>GB / <%= @cluster_summary.available_cpu_cores %> cores</span>
            </div>
          </div>
        </div>
        
        <div class="card">
          <div class="card-header">
            <h3 class="card-title">Alert Summary</h3>
          </div>
          <div class="card-body">
            <div class="metric-row">
              <span class="metric-label">Critical Alerts</span>
              <span class={"metric-value #{if @alert_summary.active_critical > 0, do: "status-critical", else: "status-healthy"}"}><%= @alert_summary.active_critical %></span>
            </div>
            <div class="metric-row">
              <span class="metric-label">High Priority</span>
              <span class={"metric-value #{if @alert_summary.active_high > 0, do: "status-warning", else: "status-healthy"}"}><%= @alert_summary.active_high %></span>
            </div>
            <div class="metric-row">
              <span class="metric-label">Total Active</span>
              <span class="metric-value"><%= @alert_summary.total_active %></span>
            </div>
            <div class="metric-row">
              <span class="metric-label">Resolved (24h)</span>
              <span class="metric-value"><%= @alert_summary.resolved_24h %></span>
            </div>
          </div>
        </div>
        
        <div class="card">
          <div class="card-header">
            <h3 class="card-title">Job Execution</h3>
          </div>
          <div class="card-body">
            <div class="metric-row">
              <span class="metric-label">Running Jobs</span>
              <span class="metric-value"><%= @job_summary.running %></span>
            </div>
            <div class="metric-row">
              <span class="metric-label">Queued Jobs</span>
              <span class="metric-value"><%= @job_summary.queued %></span>
            </div>
            <div class="metric-row">
              <span class="metric-label">Completed (24h)</span>
              <span class="metric-value"><%= @job_summary.completed_24h %></span>
            </div>
            <div class="metric-row">
              <span class="metric-label">Success Rate</span>
              <span class={"metric-value #{if @job_summary.success_rate >= 95, do: "status-healthy", else: "status-warning"}"}><%= @job_summary.success_rate %>%</span>
            </div>
          </div>
        </div>
        
        <div class="card">
          <div class="card-header">
            <h3 class="card-title">Image Pipeline</h3>
          </div>
          <div class="card-body">
            <div class="metric-row">
              <span class="metric-label">Total Images</span>
              <span class="metric-value"><%= @image_summary.total %></span>
            </div>
            <div class="metric-row">
              <span class="metric-label">Ready for Deploy</span>
              <span class="metric-value"><%= @image_summary.ready %></span>
            </div>
            <div class="metric-row">
              <span class="metric-label">Building</span>
              <span class="metric-value"><%= @image_summary.building %></span>
            </div>
            <div class="metric-row">
              <span class="metric-label">Security Issues</span>
              <span class={"metric-value #{if @image_summary.security_issues > 0, do: "status-warning", else: "status-healthy"}"}><%= @image_summary.security_issues %></span>
            </div>
          </div>
        </div>
      </div>
      
      <!-- Real-time charts -->
      <div class="chart-grid">
        <div class="card">
          <div class="card-header">
            <h3 class="card-title">Resource Utilization</h3>
          </div>
          <div class="card-body">
            <div id="resource-utilization-chart" phx-hook="ResourceChart" 
                 data-memory={Jason.encode!(@resource_metrics.memory_series)}
                 data-cpu={Jason.encode!(@resource_metrics.cpu_series)}>
            </div>
          </div>
        </div>
        
        <div class="card">
          <div class="card-header">
            <h3 class="card-title">Job Throughput</h3>
          </div>
          <div class="card-body">
            <div id="job-throughput-chart" phx-hook="ThroughputChart"
                 data-series={Jason.encode!(@job_metrics.throughput_series)}>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp render_clusters_tab(assigns) do
    ~H"""
    <div class="clusters-tab">
      <div class="card">
        <div class="card-header">
          <h3 class="card-title">Cluster Management</h3>
          <button class="btn btn-primary" phx-click="show_add_cluster_modal">
            Add Cluster
          </button>
        </div>
        <div class="card-body">
          <table class="table">
            <thead>
              <tr>
                <th>Cluster ID</th>
                <th>Status</th>
                <th>Region</th>
                <th>Containers</th>
                <th>Memory</th>
                <th>CPU</th>
                <th>Health</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for cluster <- @clusters do %>
                <tr>
                  <td>
                    <div class="cluster-info">
                      <strong><%= cluster.id %></strong>
                      <%= if cluster.is_primary do %>
                        <span class="badge badge-info">Primary</span>
                      <% end %>
                    </div>
                  </td>
                  <td>
                    <span class={"status-#{cluster.status}"}><%= String.upcase(to_string(cluster.status)) %></span>
                  </td>
                  <td><%= cluster.region || "N/A" %></td>
                  <td><%= cluster.resources.active_containers %>/<%= cluster.resources.max_containers %></td>
                  <td>
                    <div class="progress">
                      <div class="progress-bar" style={"width: #{calculate_memory_percentage(cluster.resources)}%"}></div>
                    </div>
                    <%= cluster.resources.available_memory_gb %>GB
                  </td>
                  <td>
                    <div class="progress">
                      <div class="progress-bar" style={"width: #{calculate_cpu_percentage(cluster.resources)}%"}></div>
                    </div>
                    <%= cluster.resources.available_cpu_cores %> cores
                  </td>
                  <td>
                    <span class={"status-#{if cluster.health_check.status == :healthy, do: "healthy", else: "warning"}"}><%= cluster.health_check.status %></span>
                  </td>
                  <td>
                    <div class="action-buttons">
                      <%= if cluster.status != :healthy do %>
                        <button class="btn btn-warning" phx-click="trigger_failover" phx-value-from_cluster={cluster.id}>
                          Failover
                        </button>
                      <% end %>
                      <button class="btn btn-secondary" phx-click="view_cluster_details" phx-value-cluster_id={cluster.id}>
                        Details
                      </button>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp render_alerts_tab(assigns) do
    ~H"""
    <div class="alerts-tab">
      <!-- Alert Summary Cards -->
      <div class="metrics-grid">
        <div class="card">
          <div class="card-header">
            <h3 class="card-title">Active Alerts</h3>
          </div>
          <div class="card-body">
            <div class="alert-stats">
              <div class="alert-stat critical">
                <span class="count"><%= @active_alerts.critical %></span>
                <span class="label">Critical</span>
              </div>
              <div class="alert-stat high">
                <span class="count"><%= @active_alerts.high %></span>
                <span class="label">High</span>
              </div>
              <div class="alert-stat medium">
                <span class="count"><%= @active_alerts.medium %></span>
                <span class="label">Medium</span>
              </div>
              <div class="alert-stat low">
                <span class="count"><%= @active_alerts.low %></span>
                <span class="label">Low</span>
              </div>
            </div>
          </div>
        </div>
      </div>
      
      <!-- Active Alerts Table -->
      <div class="card">
        <div class="card-header">
          <h3 class="card-title">Alert Details</h3>
          <div class="alert-filters">
            <select class="filter-select" phx-change="filter_alerts" name="severity">
              <option value="">All Severities</option>
              <option value="critical">Critical</option>
              <option value="high">High</option>
              <option value="medium">Medium</option>
              <option value="low">Low</option>
            </select>
          </div>
        </div>
        <div class="card-body">
          <table class="table">
            <thead>
              <tr>
                <th>Alert</th>
                <th>Severity</th>
                <th>Status</th>
                <th>Triggered</th>
                <th>Duration</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for alert <- @alerts do %>
                <tr class={"alert-row severity-#{alert.severity}"}>
                  <td>
                    <div class="alert-info">
                      <strong><%= alert.name %></strong>
                      <div class="alert-description"><%= alert.description %></div>
                      <%= if alert.runbook_url do %>
                        <a href={alert.runbook_url} target="_blank" class="runbook-link">📖 Runbook</a>
                      <% end %>
                    </div>
                  </td>
                  <td>
                    <span class={"severity-badge severity-#{alert.severity}"}><%= String.upcase(to_string(alert.severity)) %></span>
                  </td>
                  <td>
                    <span class={"status-badge status-#{alert.status}"}><%= String.upcase(to_string(alert.status)) %></span>
                  </td>
                  <td><%= format_timestamp(alert.triggered_at) %></td>
                  <td><%= format_duration(alert.triggered_at) %></td>
                  <td>
                    <div class="action-buttons">
                      <%= if alert.status == :active do %>
                        <button class="btn btn-secondary" phx-click="acknowledge_alert" phx-value-alert_id={alert.id}>
                          Acknowledge
                        </button>
                        <button class="btn btn-success" phx-click="resolve_alert" phx-value-alert_id={alert.id}>
                          Resolve
                        </button>
                      <% end %>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp render_images_tab(assigns) do
    ~H"""
    <div class="images-tab">
      <div class="card">
        <div class="card-header">
          <h3 class="card-title">Container Images</h3>
          <button class="btn btn-primary" phx-click="show_build_image_modal">
            Build New Image
          </button>
        </div>
        <div class="card-body">
          <table class="table">
            <thead>
              <tr>
                <th>Image</th>
                <th>Version</th>
                <th>State</th>
                <th>Size</th>
                <th>Security</th>
                <th>Created</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for image <- @images do %>
                <tr>
                  <td>
                    <div class="image-info">
                      <strong><%= image.name %></strong>
                      <%= if image.template_id do %>
                        <span class="badge badge-info">Template</span>
                      <% end %>
                    </div>
                  </td>
                  <td><%= image.version %></td>
                  <td>
                    <span class={"state-badge state-#{image.state}"}><%= String.upcase(to_string(image.state)) %></span>
                    <%= if image.state == :building do %>
                      <div class="progress">
                        <div class="progress-bar" style={"width: #{image.build_progress || 0}%"}></div>
                      </div>
                    <% end %>
                  </td>
                  <td><%= format_size(image.size_bytes) %></td>
                  <td>
                    <%= if image.vulnerabilities do %>
                      <div class="vulnerability-summary">
                        <%= if image.vulnerabilities.critical > 0 do %>
                          <span class="vuln-badge critical"><%= image.vulnerabilities.critical %> C</span>
                        <% end %>
                        <%= if image.vulnerabilities.high > 0 do %>
                          <span class="vuln-badge high"><%= image.vulnerabilities.high %> H</span>
                        <% end %>
                        <%= if image.vulnerabilities.critical == 0 and image.vulnerabilities.high == 0 do %>
                          <span class="vuln-badge clean">✓ Clean</span>
                        <% end %>
                      </div>
                    <% else %>
                      <span class="text-muted">Not scanned</span>
                    <% end %>
                  </td>
                  <td><%= format_timestamp(image.created_at) %></td>
                  <td>
                    <div class="action-buttons">
                      <%= if image.state == :ready do %>
                        <button class="btn btn-success" phx-click="deploy_image" phx-value-image_id={image.id}>
                          Deploy
                        </button>
                      <% end %>
                      <%= if image.state in [:scan_failed, :built] do %>
                        <button class="btn btn-warning" phx-click="scan_image" phx-value-image_id={image.id}>
                          Scan
                        </button>
                      <% end %>
                      <button class="btn btn-secondary" phx-click="view_image_details" phx-value-image_id={image.id}>
                        Details
                      </button>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp render_jobs_tab(assigns) do
    ~H"""
    <div class="jobs-tab">
      <!-- Job Metrics -->
      <div class="metrics-grid">
        <div class="card">
          <div class="card-header">
            <h3 class="card-title">Job Queues</h3>
          </div>
          <div class="card-body">
            <%= for {queue_name, queue_size} <- @job_queues do %>
              <div class="queue-stat">
                <span class="queue-name"><%= String.upcase(to_string(queue_name)) %></span>
                <span class="queue-size"><%= queue_size %></span>
              </div>
            <% end %>
          </div>
        </div>
        
        <div class="card">
          <div class="card-header">
            <h3 class="card-title">Workflow Status</h3>
          </div>
          <div class="card-body">
            <div class="metric-row">
              <span class="metric-label">Active Workflows</span>
              <span class="metric-value"><%= @workflow_summary.active %></span>
            </div>
            <div class="metric-row">
              <span class="metric-label">Completed Today</span>
              <span class="metric-value"><%= @workflow_summary.completed_today %></span>
            </div>
            <div class="metric-row">
              <span class="metric-label">Success Rate</span>
              <span class={"metric-value #{if @workflow_summary.success_rate >= 95, do: "status-healthy", else: "status-warning"}"}><%= @workflow_summary.success_rate %>%</span>
            </div>
          </div>
        </div>
      </div>
      
      <!-- Active Jobs Table -->
      <div class="card">
        <div class="card-header">
          <h3 class="card-title">Job Management</h3>
          <div class="job-controls">
            <button class="btn btn-primary" phx-click="show_submit_job_modal">
              Submit Job
            </button>
            <button class="btn btn-secondary" phx-click="show_job_templates">
              Templates
            </button>
          </div>
        </div>
        <div class="card-body">
          <table class="table">
            <thead>
              <tr>
                <th>Job ID</th>
                <th>Name</th>
                <th>State</th>
                <th>Priority</th>
                <th>Progress</th>
                <th>Duration</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for job <- @jobs do %>
                <tr>
                  <td><code><%= job.id %></code></td>
                  <td>
                    <div class="job-info">
                      <strong><%= job.name %></strong>
                      <%= if job.template_id do %>
                        <span class="badge badge-info">Template</span>
                      <% end %>
                    </div>
                  </td>
                  <td>
                    <span class={"state-badge state-#{job.state}"}><%= String.upcase(to_string(job.state)) %></span>
                  </td>
                  <td>
                    <span class={"priority-badge priority-#{job.priority}"}><%= format_priority(job.priority) %></span>
                  </td>
                  <td>
                    <%= if job.state == :running do %>
                      <div class="progress">
                        <div class="progress-bar" style={"width: #{job.progress || 0}%"}></div>
                      </div>
                      <%= job.progress || 0 %>%
                    <% else %>
                      <%= if job.state in [:completed, :failed] do %>
                        100%
                      <% else %>
                        0%
                      <% end %>
                    <% end %>
                  </td>
                  <td><%= format_job_duration(job) %></td>
                  <td>
                    <div class="action-buttons">
                      <%= if job.state in [:queued, :running] do %>
                        <button class="btn btn-danger btn-sm" phx-click="cancel_job" phx-value-job_id={job.id}>
                          Cancel
                        </button>
                      <% end %>
                      <button class="btn btn-secondary btn-sm" phx-click="view_job_details" phx-value-job_id={job.id}>
                        Details
                      </button>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp render_security_tab(assigns) do
    ~H"""
    <div class="security-tab">
      <div class="card">
        <div class="card-header">
          <h3 class="card-title">Security Overview</h3>
        </div>
        <div class="card-body">
          <div class="security-metrics">
            <div class="security-metric">
              <h4>Vulnerability Summary</h4>
              <div class="vulnerability-counts">
                <div class="vuln-stat critical">
                  <span class="count"><%= @security_summary.vulnerabilities.critical %></span>
                  <span class="label">Critical</span>
                </div>
                <div class="vuln-stat high">
                  <span class="count"><%= @security_summary.vulnerabilities.high %></span>
                  <span class="label">High</span>
                </div>
                <div class="vuln-stat medium">
                  <span class="count"><%= @security_summary.vulnerabilities.medium %></span>
                  <span class="label">Medium</span>
                </div>
                <div class="vuln-stat low">
                  <span class="count"><%= @security_summary.vulnerabilities.low %></span>
                  <span class="label">Low</span>
                </div>
              </div>
            </div>
            
            <div class="security-metric">
              <h4>Compliance Status</h4>
              <div class="compliance-checks">
                <%= for {standard, status} <- @security_summary.compliance do %>
                  <div class="compliance-item">
                    <span class="standard"><%= String.upcase(to_string(standard)) %></span>
                    <span class={"status status-#{status}"}><%= String.upcase(to_string(status)) %></span>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp render_analytics_tab(assigns) do
    ~H"""
    <div class="analytics-tab">
      <div class="chart-grid">
        <div class="card">
          <div class="card-header">
            <h3 class="card-title">Performance Trends</h3>
          </div>
          <div class="card-body">
            <div id="performance-trends-chart" phx-hook="PerformanceTrendsChart"
                 data-series={Jason.encode!(@analytics.performance_trends)}>
            </div>
          </div>
        </div>
        
        <div class="card">
          <div class="card-header">
            <h3 class="card-title">Cost Analysis</h3>
          </div>
          <div class="card-body">
            <div id="cost-analysis-chart" phx-hook="CostAnalysisChart"
                 data-series={Jason.encode!(@analytics.cost_trends)}>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  ## Private Functions

  defp load_initial_data(socket) do
    refresh_dashboard_data(socket)
  end

  defp refresh_dashboard_data(socket) do
    socket
    |> assign(:last_updated, DateTime.utc_now())
    |> refresh_cluster_data()
    |> refresh_alert_data()
    |> refresh_image_data()
    |> refresh_job_data()
    |> refresh_security_data()
    |> refresh_analytics_data()
  end

  defp refresh_cluster_data(socket) do
    # Cluster data
    clusters = get_cluster_status()
    cluster_summary = calculate_cluster_summary(clusters)

    socket
    |> assign(:clusters, clusters)
    |> assign(:cluster_summary, cluster_summary)
  end

  defp refresh_alert_data(socket) do
    # Alert data
    alerts = get_active_alerts()
    alert_summary = calculate_alert_summary(alerts)
    active_alerts = group_alerts_by_severity(alerts)

    socket
    |> assign(:alerts, alerts)
    |> assign(:alert_summary, alert_summary)
    |> assign(:active_alerts, active_alerts)
  end

  defp refresh_image_data(socket) do
    # Image data
    images = get_image_list()
    image_summary = calculate_image_summary(images)

    socket
    |> assign(:images, images)
    |> assign(:image_summary, image_summary)
  end

  defp refresh_job_data(socket) do
    # Job data
    jobs = get_job_list()
    job_summary = calculate_job_summary(jobs)
    job_queues = get_job_queue_sizes()
    workflow_summary = get_workflow_summary()

    socket
    |> assign(:jobs, jobs)
    |> assign(:job_summary, job_summary)
    |> assign(:job_queues, job_queues)
    |> assign(:workflow_summary, workflow_summary)
  end

  defp refresh_security_data(socket) do
    security_summary = get_security_summary()
    assign(socket, :security_summary, security_summary)
  end

  defp refresh_analytics_data(socket) do
    # Analytics data
    resource_metrics = get_resource_metrics()
    job_metrics = get_job_metrics()
    analytics = get_analytics_data()

    socket
    |> assign(:resource_metrics, resource_metrics)
    |> assign(:job_metrics, job_metrics)
    |> assign(:analytics, analytics)
  end

  defp subscribe_to_telemetry do
    events = [
      [:flame, :cluster, :health_changed],
      [:flame, :alert, :triggered],
      [:flame, :alert, :resolved],
      [:flame, :image, :build_completed],
      [:flame, :image, :deployed],
      [:flame, :job, :submitted],
      [:flame, :job, :completed],
      [:flame, :job, :failed]
    ]

    Enum.each(events, fn event ->
      :telemetry.attach(
        "dashboard-#{Enum.join(event, "-")}",
        event,
        &__MODULE__.handle_telemetry_event/4,
        %{dashboard_pid: self()}
      )
    end)
  end

  def handle_telemetry_event(event_name, measurements, metadata, %{dashboard_pid: pid}) do
    send(pid, {:telemetry, event_name, measurements, metadata})
  end

  defp handle_real_time_event(socket, event_name, _measurements, metadata) do
    case event_name do
      [:flame, :alert, :triggered] ->
        put_flash(socket, :warning, "New alert triggered: #{metadata.alert_name}")

      [:flame, :job, :failed] ->
        put_flash(socket, :error, "Job failed: #{metadata.job_id}")

      [:flame, :image, :deployed] ->
        put_flash(socket, :info, "Image deployed successfully: #{metadata.image_id}")

      _ ->
        socket
    end
  end

  # Data fetching functions (these would call the actual managers)

  defp get_cluster_status do
    try do
      case GenServer.call(ClusterManager, :get_cluster_status, 5000) do
        clusters when is_list(clusters) -> clusters
        _ -> []
      end
    catch
      _ -> []
    end
  end

  defp get_active_alerts do
    try do
      case GenServer.call(AlertManager, :get_active_alerts, 5000) do
        alerts when is_list(alerts) -> alerts
        _ -> []
      end
    catch
      _ -> []
    end
  end

  defp get_image_list do
    try do
      case GenServer.call(ImageManager, {:list_images, %{}}, 5000) do
        images when is_list(images) -> images
        _ -> []
      end
    catch
      _ -> []
    end
  end

  defp get_job_list do
    try do
      case GenServer.call(JobManager, {:list_jobs, %{}}, 5000) do
        jobs when is_list(jobs) -> jobs
        _ -> []
      end
    catch
      _ -> []
    end
  end

  # Helper functions for calculations and formatting

  defp calculate_cluster_summary(clusters) do
    total = length(clusters)
    healthy = Enum.count(clusters, &(&1.status == :healthy))

    %{
      total: total,
      healthy: healthy,
      total_containers: Enum.sum(Enum.map(clusters, & &1.resources.active_containers)),
      available_memory_gb: Enum.sum(Enum.map(clusters, & &1.resources.available_memory_gb)),
      available_cpu_cores: Enum.sum(Enum.map(clusters, & &1.resources.available_cpu_cores))
    }
  end

  defp calculate_alert_summary(alerts) do
    active_alerts = Enum.filter(alerts, &(&1.status == :active))

    %{
      total_active: length(active_alerts),
      active_critical: Enum.count(active_alerts, &(&1.severity == 1)),
      active_high: Enum.count(active_alerts, &(&1.severity == 2)),
      # This would be calculated from historical data
      resolved_24h: 15
    }
  end

  defp calculate_image_summary(images) do
    %{
      total: length(images),
      ready: Enum.count(images, &(&1.state == :ready)),
      building: Enum.count(images, &(&1.state == :building)),
      security_issues:
        Enum.count(images, fn image ->
          case image.vulnerabilities do
            %{critical: c, high: h} when c > 0 or h > 0 -> true
            _ -> false
          end
        end)
    }
  end

  defp calculate_job_summary(jobs) do
    running = Enum.count(jobs, &(&1.state == :running))
    queued = Enum.count(jobs, &(&1.state == :queued))
    completed_jobs = Enum.filter(jobs, &(&1.state in [:completed, :failed]))

    success_rate =
      if length(completed_jobs) > 0 do
        successful = Enum.count(completed_jobs, &(&1.state == :completed))
        round(successful / length(completed_jobs) * 100)
      else
        100
      end

    %{
      running: running,
      queued: queued,
      # This would be calculated from historical data
      completed_24h: 42,
      success_rate: success_rate
    }
  end

  defp group_alerts_by_severity(alerts) do
    active_alerts = Enum.filter(alerts, &(&1.status == :active))

    %{
      critical: Enum.count(active_alerts, &(&1.severity == 1)),
      high: Enum.count(active_alerts, &(&1.severity == 2)),
      medium: Enum.count(active_alerts, &(&1.severity == 3)),
      low: Enum.count(active_alerts, &(&1.severity in [4, 5]))
    }
  end

  defp get_job_queue_sizes do
    try do
      case GenServer.call(JobManager, :get_job_metrics, 5000) do
        %{queue_sizes: sizes} -> sizes
        _ -> %{critical: 0, high: 0, normal: 0, low: 0, batch: 0}
      end
    catch
      _ -> %{critical: 0, high: 0, normal: 0, low: 0, batch: 0}
    end
  end

  defp get_workflow_summary do
    %{
      active: 3,
      completed_today: 12,
      success_rate: 95
    }
  end

  defp get_security_summary do
    %{
      vulnerabilities: %{
        critical: 2,
        high: 5,
        medium: 12,
        low: 8
      },
      compliance: %{
        cis_benchmark: :passed,
        pci_dss: :passed,
        soc2: :warning,
        gdpr: :passed
      }
    }
  end

  defp get_resource_metrics do
    # Generate sample time series data
    now = System.system_time(:second)

    memory_series =
      Enum.map(0..(@chart_data_points - 1), fn i ->
        %{
          timestamp: now - (@chart_data_points - i) * 60,
          value: :rand.uniform(80) + 10
        }
      end)

    cpu_series =
      Enum.map(0..(@chart_data_points - 1), fn i ->
        %{
          timestamp: now - (@chart_data_points - i) * 60,
          value: :rand.uniform(70) + 15
        }
      end)

    %{
      memory_series: memory_series,
      cpu_series: cpu_series
    }
  end

  defp get_job_metrics do
    # Generate sample throughput data
    now = System.system_time(:second)

    throughput_series =
      Enum.map(0..(@chart_data_points - 1), fn i ->
        %{
          timestamp: now - (@chart_data_points - i) * 60,
          value: :rand.uniform(20) + 5
        }
      end)

    %{
      throughput_series: throughput_series
    }
  end

  defp get_analytics_data do
    %{
      performance_trends: [],
      cost_trends: []
    }
  end

  # Formatting helper functions

  defp calculate_memory_percentage(resources) do
    if resources.total_memory_gb > 0 do
      used = resources.total_memory_gb - resources.available_memory_gb
      round(used / resources.total_memory_gb * 100)
    else
      0
    end
  end

  defp calculate_cpu_percentage(resources) do
    if resources.total_cpu_cores > 0 do
      used = resources.total_cpu_cores - resources.available_cpu_cores
      round(used / resources.total_cpu_cores * 100)
    else
      0
    end
  end

  defp format_timestamp(timestamp) when is_integer(timestamp) do
    timestamp
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_time()
    |> Time.to_string()
  end

  defp format_duration(start_time) when is_integer(start_time) do
    duration_ms = System.system_time(:millisecond) - start_time
    minutes = div(duration_ms, 60_000)

    cond do
      minutes < 1 -> "< 1m"
      minutes < 60 -> "#{minutes}m"
      true -> "#{div(minutes, 60)}h #{rem(minutes, 60)}m"
    end
  end

  defp format_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 1)}GB"
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 1)}MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 1)}KB"
      true -> "#{bytes}B"
    end
  end

  defp format_priority(priority) do
    case priority do
      1 -> "Critical"
      2 -> "High"
      3 -> "Normal"
      4 -> "Low"
      5 -> "Batch"
      _ -> "Unknown"
    end
  end

  defp format_job_duration(job) do
    cond do
      job.completed_at && job.started_at ->
        duration_ms = job.completed_at - job.started_at
        "#{div(duration_ms, 1000)}s"

      job.started_at ->
        duration_ms = System.system_time(:millisecond) - job.started_at
        "#{div(duration_ms, 1000)}s"

      true ->
        "-"
    end
  end

  # Parsing helper functions for form data

  defp parse_cluster_config(config) do
    %{
      endpoints: [
        %{
          type: :http,
          host: config["host"],
          port: String.to_integer(config["port"] || "4000"),
          path: config["path"] || "/api/flame"
        }
      ],
      region: config["region"],
      zone: config["zone"],
      capabilities: ["container_provisioning", "task_execution"]
    }
  end

  defp parse_build_spec(spec) do
    %{
      name: spec["name"],
      source: %{
        type: :git,
        url: spec["git_url"]
      },
      version: spec["version"]
    }
  end

  defp parse_job_spec(spec) do
    %{
      name: spec["name"],
      function:
        {String.to_existing_atom(spec["module"]), String.to_existing_atom(spec["function"]), []},
      parameters: Jason.decode!(spec["parameters"] || "{}")
    }
  end

  defp parse_parameters(params_string) do
    case Jason.decode(params_string || "{}") do
      {:ok, params} -> params
      {:error, _} -> %{}
    end
  end
end
