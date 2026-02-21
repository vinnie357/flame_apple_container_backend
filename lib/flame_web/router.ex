defmodule FlameWeb.Router do
  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {FlameWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", FlameWeb do
    pipe_through(:browser)

    live("/", DashboardRouter, :index, as: :dashboard_router)
    live("/dashboard", DashboardRouter, :index, as: :dashboard_router)

    # Enterprise Dashboard
    live("/enterprise-dashboard", EnterpriseDashboardLive, :index)
    live("/enterprise-dashboard/:tab", EnterpriseDashboardLive, :tab)

    # Test endpoints for integration testing
    get("/test/run_job", TestController, :run_job)
    get("/test/status", TestController, :status)
    post("/test/execute", TestController, :execute)
  end

  scope "/api", FlameWeb do
    pipe_through(:api)

    # Test endpoints for integration testing
    post("/test/run", TestController, :run_job)
    get("/test/status", TestController, :status)
    post("/test/execute", TestController, :execute)

    # Existing endpoints
    get("/metrics/prometheus", MetricsController, :prometheus)
    get("/health", HealthController, :check)

    # REST API v1 endpoints
    scope "/v1" do
      # Cluster management
      get("/clusters", ApiController, :list_clusters)
      get("/clusters/:cluster_id", ApiController, :get_cluster)
      post("/clusters", ApiController, :create_cluster)
      delete("/clusters/:cluster_id", ApiController, :delete_cluster)
      post("/clusters/:cluster_id/failover", ApiController, :trigger_failover)

      # Job management
      get("/jobs", ApiController, :list_jobs)
      get("/jobs/:job_id", ApiController, :get_job)
      post("/jobs", ApiController, :create_job)
      delete("/jobs/:job_id", ApiController, :cancel_job)

      # Workflow management
      get("/workflows", ApiController, :list_workflows)
      post("/workflows", ApiController, :create_workflow)

      # Image management
      get("/images", ApiController, :list_images)
      get("/images/:image_id", ApiController, :get_image)
      post("/images/build", ApiController, :build_image)
      post("/images/:image_id/deploy", ApiController, :deploy_image)
      post("/images/:image_id/scan", ApiController, :scan_image)

      # Alert management
      get("/alerts", ApiController, :list_alerts)
      post("/alerts/:alert_id/acknowledge", ApiController, :acknowledge_alert)
      post("/alerts/:alert_id/resolve", ApiController, :resolve_alert)

      # Metrics and analytics
      get("/metrics/overview", ApiController, :metrics_overview)
      get("/metrics/performance", ApiController, :performance_metrics)
      get("/health", ApiController, :health_check)
    end
  end

  # GraphQL disabled for simplicity

  # Enable LiveDashboard in development
  if Application.compile_env(:flame_apple_container_backend, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: FlameWeb.Telemetry)
    end
  end
end
