defmodule FLAME.AppleContainers.Supervisor do
  @moduledoc """
  Supervisor for FLAME Apple Containers backend components.

  This supervisor manages the lifecycle of all Apple Containers backend
  components including the manager, pool, and monitoring systems.

  ## Architecture

  The supervision tree is structured as follows:

      FLAME.AppleContainers.Supervisor
      ├── FLAME.AppleContainers.Manager (main API)
      │   ├── FLAME.AppleContainers.Pool (container management)
      │   └── FLAME.AppleContainers.Monitor (health monitoring)
      └── Global services (shared across instances)
          ├── FLAME.ContainerMetrics
          ├── FLAME.CircuitBreaker
          └── Other shared services

  ## Configuration

  The supervisor can be configured with various options:

  - `:manager_config` - Configuration for the main manager
  - `:pool_config` - Configuration for the container pool
  - `:monitor_config` - Configuration for health monitoring
  - `:global_services` - List of global services to start

  ## Usage

      # Start with default configuration
      {:ok, supervisor} = FLAME.AppleContainers.Supervisor.start_link([])
      
      # Start with custom configuration
      {:ok, supervisor} = FLAME.AppleContainers.Supervisor.start_link([
        manager_config: [
          pool_size: 5,
          max_pool_size: 15,
          image: "my-worker:latest"
        ],
        monitor_config: [
          health_check_interval: 15_000
        ]
      ])
  """

  use Supervisor
  require Logger
  alias FLAME.AppleContainers.Manager

  @default_config %{
    manager_config: [
      image: "flame-worker:latest",
      pool_size: 3,
      max_pool_size: 10,
      dns_domain: "flame.local",
      erlang_cookie: nil
    ],
    monitor_config: [
      health_check_interval: 30_000,
      metrics_collection_interval: 60_000
    ],
    global_services: [
      :container_metrics,
      :circuit_breaker,
      :container_health,
      :resource_manager
    ]
  }

  @doc """
  Starts the FLAME Apple Containers supervisor.

  ## Options

  - `:manager_config` - Configuration passed to FLAME.AppleContainers.Manager
  - `:monitor_config` - Configuration passed to FLAME.AppleContainers.Monitor  
  - `:global_services` - List of global services to start
  - `:name` - Name for the supervisor process

  ## Examples

      {:ok, supervisor} = FLAME.AppleContainers.Supervisor.start_link([
        manager_config: [pool_size: 5],
        name: MyApp.FlameSupervisor
      ])
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Gets the PID of the manager process managed by this supervisor.

  ## Parameters

  - `supervisor` - Supervisor PID or name

  ## Returns

  - `{:ok, manager_pid}` - Manager process found
  - `{:error, :not_found}` - Manager process not found

  ## Examples

      {:ok, manager} = FLAME.AppleContainers.Supervisor.get_manager(supervisor)
  """
  def get_manager(supervisor \\ __MODULE__) do
    case Supervisor.which_children(supervisor) do
      children when is_list(children) ->
        find_manager_in_children(children)

      _ ->
        {:error, :not_found}
    end
  end

  defp find_manager_in_children(children) do
    case Enum.find(children, fn {id, _pid, _type, _modules} ->
           id == FLAME.AppleContainers.Manager
         end) do
      {_id, pid, _type, _modules} when is_pid(pid) ->
        {:ok, pid}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets the PID of the monitor process managed by this supervisor.

  ## Parameters

  - `supervisor` - Supervisor PID or name

  ## Returns

  - `{:ok, monitor_pid}` - Monitor process found
  - `{:error, :not_found}` - Monitor process not found

  ## Examples

      {:ok, monitor} = FLAME.AppleContainers.Supervisor.get_monitor(supervisor)
  """
  def get_monitor(supervisor \\ __MODULE__) do
    case get_manager(supervisor) do
      {:ok, _manager} ->
        # Monitor is managed by the manager, so we'd need to ask the manager
        # For now, return not_found as monitor isn't directly supervised here
        {:error, :not_found}

      error ->
        error
    end
  end

  @doc """
  Gets the current status of all managed components.

  ## Parameters

  - `supervisor` - Supervisor PID or name

  ## Returns

  A map containing status information for all components.

  ## Examples

      status = FLAME.AppleContainers.Supervisor.get_status(supervisor)
  """
  def get_status(supervisor \\ __MODULE__) do
    children = Supervisor.which_children(supervisor)

    %{
      supervisor: supervisor,
      children_count: length(children),
      children:
        Enum.map(children, fn {id, pid, type, modules} ->
          %{
            id: id,
            pid: pid,
            type: type,
            modules: modules,
            alive: is_pid(pid) and Process.alive?(pid)
          }
        end),
      manager_status: get_component_status(:manager, supervisor),
      global_services_status: get_global_services_status(children)
    }
  end

  ## Supervisor Implementation

  @impl true
  def init(opts) do
    config = merge_config(opts)

    Logger.info(
      "Starting FLAME Apple Containers Supervisor with config: #{inspect(config, pretty: true)}"
    )

    children = build_children_specs(config)

    Logger.info("Starting #{length(children)} child processes")

    Supervisor.init(children, strategy: :one_for_one)
  end

  ## Private Helper Functions

  defp merge_config(opts) do
    base_config = @default_config

    Enum.reduce(opts, base_config, fn {key, value}, acc ->
      case key do
        :manager_config ->
          existing = Map.get(acc, :manager_config, [])
          updated = Keyword.merge(existing, value)
          Map.put(acc, :manager_config, updated)

        :monitor_config ->
          existing = Map.get(acc, :monitor_config, [])
          updated = Keyword.merge(existing, value)
          Map.put(acc, :monitor_config, updated)

        :global_services ->
          Map.put(acc, :global_services, value)

        :name ->
          # Don't include supervisor name in config
          acc

        _ ->
          Map.put(acc, key, value)
      end
    end)
  end

  defp build_children_specs(config) do
    children = []

    # Add global services first
    children = children ++ build_global_services_specs(config.global_services)

    # Add main manager (which will start its own pool and monitor)
    children = children ++ [build_manager_spec(config.manager_config)]

    # Filter out any nil specs
    Enum.filter(children, & &1)
  end

  defp build_global_services_specs(services) do
    Enum.map(services, &build_global_service_spec/1)
    |> Enum.filter(& &1)
  end

  defp build_global_service_spec(service) do
    case service do
      :container_metrics ->
        build_service_spec_if_available(FLAME.ContainerMetrics)

      :circuit_breaker ->
        build_service_spec_if_available(FLAME.CircuitBreaker)

      :container_health ->
        build_service_spec_if_available(FLAME.ContainerHealth)

      :resource_manager ->
        build_service_spec_if_available(FLAME.ResourceManager)

      service_name when is_atom(service_name) ->
        Logger.warning("Unknown global service: #{service_name}, skipping")
        nil

      {module, args} when is_atom(module) and is_list(args) ->
        build_service_spec_if_available(module, args)

      _ ->
        Logger.warning("Invalid global service specification: #{inspect(service)}, skipping")
        nil
    end
  end

  defp build_service_spec_if_available(module, args \\ []) do
    if Code.ensure_loaded?(module) do
      {module, args}
    else
      Logger.warning("#{module} not available, skipping")
      nil
    end
  end

  defp build_manager_spec(manager_config) do
    # The manager will handle starting its own pool and monitor
    {Manager, manager_config}
  end

  defp get_component_status(component, supervisor) do
    case component do
      :manager ->
        case get_manager(supervisor) do
          {:ok, manager_pid} ->
            try do
              status = Manager.get_status(manager_pid)
              Map.put(status, :pid, manager_pid)
            rescue
              e ->
                %{error: inspect(e), pid: manager_pid}
            end

          {:error, reason} ->
            %{error: reason}
        end

      _ ->
        %{error: :unknown_component}
    end
  end

  defp get_global_services_status(children) do
    global_services = [
      FLAME.ContainerMetrics,
      FLAME.CircuitBreaker,
      FLAME.ContainerHealth,
      FLAME.ResourceManager
    ]

    Enum.map(global_services, &get_service_status(&1, children))
  end

  defp get_service_status(service, children) do
    case Enum.find(children, fn {id, _pid, _type, _modules} -> id == service end) do
      {_id, pid, _type, _modules} when is_pid(pid) ->
        %{
          service: service,
          pid: pid,
          alive: Process.alive?(pid),
          status: :running
        }

      _ ->
        %{
          service: service,
          pid: nil,
          alive: false,
          status: :not_started
        }
    end
  end
end
