defmodule FlameWeb.MetricsController do
  use Phoenix.Controller, formats: [:text, :json]

  def prometheus(conn, _params) do
    case FLAME.ContainerMetrics.export_prometheus_metrics() do
      {:ok, metrics_text} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, metrics_text)

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> text("Metrics not available: #{reason}")
    end
  end
end

defmodule FlameWeb.HealthController do
  use Phoenix.Controller, formats: [:json]

  def check(conn, _params) do
    health_status = %{
      status: "healthy",
      systems: %{
        container_pool: system_health(FLAME.ContainerPool),
        metrics: system_health(FLAME.ContainerMetrics),
        security: system_health(FLAME.SecurityManager),
        resources: system_health(FLAME.ResourceManager),
        orchestrator: system_health(FLAME.Orchestrator)
      },
      timestamp: System.system_time(:millisecond)
    }

    overall_healthy =
      Enum.all?(health_status.systems, fn {_name, status} ->
        status == "healthy"
      end)

    status_code = if overall_healthy, do: 200, else: 503

    conn
    |> put_status(status_code)
    |> json(health_status)
  end

  defp system_health(module) do
    case Process.whereis(module) do
      nil -> "down"
      pid when is_pid(pid) -> "healthy"
    end
  end
end
