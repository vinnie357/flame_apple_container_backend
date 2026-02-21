defmodule FlameAppleContainerBackend.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Get configuration
    config = get_application_config()

    children =
      [
        # FLAME Pool (primary functionality)
        maybe_start_flame_pool(config),

        # Core FLAME systems (always available)
        maybe_start_core_system(FLAME.CircuitBreakerSupervisor, [], config),
        maybe_start_core_system(FLAME.ContainerMetrics, [], config),
        maybe_start_core_system(FLAME.ContainerHealth, [], config),
        maybe_start_core_system(FLAME.SecurityManager, [], config),
        maybe_start_core_system(FLAME.ResourceManager, [], config),
        # Temporarily disable custom container pool and orchestrator
        # maybe_start_core_system(FLAME.ContainerPool, [], config),
        # maybe_start_core_system(FLAME.Orchestrator, [], config),
        maybe_start_core_system(FLAME.FunctionOptimizer, [], config),

        # Optional systems based on configuration
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
      # Environment (test, development, production)
      environment: get_env_config(:environment, :production),

      # Core system toggles
      enable_metrics: get_env_config(:enable_metrics, true),
      enable_security: get_env_config(:enable_security, true),
      enable_resource_management: get_env_config(:enable_resource_management, true),
      enable_orchestration: get_env_config(:enable_orchestration, true),
      enable_optimization: get_env_config(:enable_optimization, true),

      # Optional system toggles
      enable_benchmarks: get_env_config(:enable_benchmarks, false),
      enable_web_interface: get_env_config(:enable_web_interface, false),
      enable_worker_server: get_env_config(:enable_worker_server, false),

      # Web configuration
      web_port: get_env_config(:web_port, 4001),
      worker_port: System.get_env("FLAME_WORKER_PORT"),

      # Mode configuration
      minimal_mode: get_env_config(:minimal_mode, false)
    }
  end

  defp get_env_config(key, default) do
    # Check environment variables first, then application config
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
    case {module, config} do
      {FLAME.ContainerMetrics, %{enable_metrics: false}} -> nil
      {FLAME.SecurityManager, %{enable_security: false}} -> nil
      {FLAME.ResourceManager, %{enable_resource_management: false}} -> nil
      {FLAME.Orchestrator, %{enable_orchestration: false}} -> nil
      {FLAME.FunctionOptimizer, %{enable_optimization: false}} -> nil
      {FLAME.ContainerHealth, %{minimal_mode: true}} -> nil
      {FLAME.Orchestrator, %{minimal_mode: true}} -> nil
      {FLAME.FunctionOptimizer, %{minimal_mode: true}} -> nil
      _ -> {module, args}
    end
  end

  defp maybe_start_benchmarks(config) do
    if config.enable_benchmarks and config.environment in [:development, :test] do
      {FLAME.BenchmarkSuite, []}
    else
      nil
    end
  end

  defp maybe_start_web_interface(config) do
    if config.enable_web_interface and phoenix_available?() do
      # Update endpoint config with the runtime port
      Application.put_env(:flame_apple_container_backend, FlameWeb.Endpoint,
        http: [ip: {127, 0, 0, 1}, port: config.web_port],
        secret_key_base: "6eKv6BRu8iTQ8LkiXwNqIEJQn6JkW7FuJ2HpNktIVJ2LxSkqHqR4B1Jg8n5HdN0J",
        live_view: [signing_salt: "VGhUQ1pH"],
        pubsub_server: FlameWeb.PubSub,
        render_errors: [accepts: ~w(html json), layout: false],
        check_origin: false
      )

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
      # Use Apple Containers backend exclusively
      {
        FLAME.Pool,
        # Increased timeout for container startup
        name: FlameAppleContainerBackend.Pool,
        min: 0,
        max: 5,
        boot_timeout: 60_000,
        idle_shutdown_after: 30_000,
        max_concurrency: 10,
        backend:
          {FLAME.AppleContainersBackend,
           [
             image: "flame-worker:test3",
             mode: :development,
             erlang_cookie: "test_cookie_123",
             # Will auto-fallback to test.local if not available
             dns_domain: "flame.local",
             container_prefix: "flame-worker"
           ]}
      }
    else
      nil
    end
  end
end
