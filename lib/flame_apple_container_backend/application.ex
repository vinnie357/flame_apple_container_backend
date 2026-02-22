defmodule FlameAppleContainerBackend.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    config = get_application_config()

    children =
      [
        maybe_start_flame_pool(config),
        maybe_start_core_system(FLAME.CircuitBreakerSupervisor, [], config),
        maybe_start_core_system(FLAME.ContainerMetrics, [], config),
        maybe_start_core_system(FLAME.ContainerHealth, [], config),
        maybe_start_core_system(FLAME.SecurityManager, [], config),
        maybe_start_core_system(FLAME.ResourceManager, [], config),
        maybe_start_core_system(FLAME.FunctionOptimizer, [], config),
        maybe_start_benchmarks(config),
        maybe_start_web_interface(config),
        maybe_start_worker_server(config)
      ]
      |> List.flatten()
      |> Enum.filter(& &1)

    opts = [strategy: :one_for_one, name: FlameAppleContainerBackend.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp get_application_config do
    %{
      environment: get_env_config(:environment, :production),
      enable_metrics: get_env_config(:enable_metrics, true),
      enable_security: get_env_config(:enable_security, true),
      enable_resource_management: get_env_config(:enable_resource_management, true),
      enable_orchestration: get_env_config(:enable_orchestration, true),
      enable_optimization: get_env_config(:enable_optimization, true),
      enable_benchmarks: get_env_config(:enable_benchmarks, false),
      enable_web_interface: get_env_config(:enable_web_interface, false),
      enable_worker_server: get_env_config(:enable_worker_server, false),
      worker_port: System.get_env("FLAME_WORKER_PORT"),
      minimal_mode: get_env_config(:minimal_mode, false)
    }
  end

  defp get_env_config(key, default) do
    env_var = "FLAME_#{String.upcase(to_string(key))}"

    case System.get_env(env_var) do
      nil ->
        Application.get_env(:flame_apple_container_backend, key, default)

      "true" ->
        true

      "false" ->
        false

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int_val, ""} -> int_val
          _ -> String.to_atom(value)
        end
    end
  end

  defp maybe_start_core_system(module, args, config) do
    if core_system_disabled?(module, config) do
      nil
    else
      {module, args}
    end
  end

  defp core_system_disabled?(FLAME.ContainerMetrics, %{enable_metrics: false}), do: true
  defp core_system_disabled?(FLAME.SecurityManager, %{enable_security: false}), do: true

  defp core_system_disabled?(FLAME.ResourceManager, %{enable_resource_management: false}),
    do: true

  defp core_system_disabled?(FLAME.Orchestrator, %{enable_orchestration: false}), do: true
  defp core_system_disabled?(FLAME.FunctionOptimizer, %{enable_optimization: false}), do: true
  defp core_system_disabled?(FLAME.ContainerHealth, %{minimal_mode: true}), do: true
  defp core_system_disabled?(FLAME.Orchestrator, %{minimal_mode: true}), do: true
  defp core_system_disabled?(FLAME.FunctionOptimizer, %{minimal_mode: true}), do: true
  defp core_system_disabled?(_module, _config), do: false

  defp maybe_start_benchmarks(config) do
    if config.enable_benchmarks and config.environment in [:development, :test] do
      {FLAME.BenchmarkSuite, []}
    else
      nil
    end
  end

  defp maybe_start_web_interface(config) do
    if config.enable_web_interface and phoenix_available?() do
      [
        {Phoenix.PubSub, name: FlameWeb.PubSub},
        {FlameWeb.Endpoint, []}
      ]
    else
      nil
    end
  end

  defp maybe_start_worker_server(config) do
    case config.worker_port do
      nil ->
        nil

      port_str when is_binary(port_str) ->
        port = String.to_integer(port_str)
        {FlameWorkerServer, [port: port]}

      port when is_integer(port) ->
        {FlameWorkerServer, [port: port]}
    end
  end

  defp phoenix_available? do
    Code.ensure_loaded?(Phoenix.Endpoint) and Code.ensure_loaded?(Phoenix.LiveView)
  end

  defp maybe_start_flame_pool(config) do
    if config.enable_web_interface or not config.minimal_mode do
      pool_config = Application.get_env(:flame_apple_container_backend, :flame_pool, %{})
      backend_config = Application.get_env(:flame_apple_container_backend, :flame_backend, %{})

      {
        FLAME.Pool,
        name: FlameAppleContainerBackend.Pool,
        min: Map.get(pool_config, :min, 0),
        max: Map.get(pool_config, :max, 5),
        boot_timeout: Map.get(pool_config, :boot_timeout, 60_000),
        idle_shutdown_after: Map.get(pool_config, :idle_shutdown_after, 30_000),
        max_concurrency: Map.get(pool_config, :max_concurrency, 10),
        backend:
          {FLAME.AppleContainersBackend,
           [
             image: Map.get(backend_config, :image, "flame-worker:latest"),
             erlang_cookie: Map.get(backend_config, :erlang_cookie, "change_me"),
             dns_domain: Map.get(backend_config, :dns_domain, "flame.local"),
             container_prefix: Map.get(backend_config, :container_prefix, "flame-worker")
           ]}
      }
    else
      nil
    end
  end
end
