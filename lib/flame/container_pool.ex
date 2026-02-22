defmodule FLAME.ContainerPool do
  @moduledoc """
  Container warm pool management for Apple Containers FLAME backend.

  Manages a pool of pre-warmed containers to reduce cold start latency,
  implements container reuse strategies, and handles graceful shutdown.
  """

  use GenServer
  require Logger

  alias FLAME.ContainerHealth
  alias FLAME.ContainerMetrics

  defstruct [
    :backend_config,
    :warm_pool,
    :active_containers,
    :pool_config,
    :health_monitor,
    :metrics_collector
  ]

  @default_pool_config %{
    min_warm_containers: 2,
    max_warm_containers: 10,
    max_active_containers: 50,
    # 5 minutes
    container_idle_timeout: 300_000,
    # 30 seconds
    health_check_interval: 30_000,
    # 1 minute
    warm_pool_check_interval: 60_000
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    backend_config = Keyword.get(opts, :backend_config, %{}) |> ensure_backend_defaults()
    pool_config = Keyword.get(opts, :pool_config, %{}) |> merge_default_config()

    state = %__MODULE__{
      backend_config: backend_config,
      warm_pool: %{},
      active_containers: %{},
      pool_config: pool_config,
      health_monitor: nil,
      metrics_collector: nil
    }

    # Get or start health monitoring
    health_monitor =
      case Process.whereis(FLAME.ContainerHealth) do
        nil ->
          {:ok, pid} = FLAME.ContainerHealth.start_link(pool_config)
          pid

        pid ->
          pid
      end

    state = %{state | health_monitor: health_monitor}

    # Get or start metrics collection
    metrics_collector =
      case Process.whereis(FLAME.ContainerMetrics) do
        nil ->
          {:ok, pid} = FLAME.ContainerMetrics.start_link(pool_config)
          pid

        pid ->
          pid
      end

    state = %{state | metrics_collector: metrics_collector}

    # Schedule warm pool maintenance
    schedule_warm_pool_maintenance()

    # Pre-warm initial containers
    send(self(), :ensure_warm_pool)

    Logger.info("Container pool initialized with config: #{inspect(pool_config)}")
    {:ok, state}
  end

  def get_container(timeout \\ 30_000) do
    GenServer.call(__MODULE__, :get_container, timeout)
  end

  def return_container(container_id) do
    GenServer.cast(__MODULE__, {:return_container, container_id})
  end

  def get_pool_status do
    GenServer.call(__MODULE__, :get_pool_status)
  end

  def terminate_container(container_id, reason \\ :normal) do
    GenServer.cast(__MODULE__, {:terminate_container, container_id, reason})
  end

  # GenServer callbacks

  def handle_call(:get_container, from, state) do
    case find_available_warm_container(state) do
      {:ok, container_id, container_info} ->
        # Move from warm pool to active
        warm_pool = Map.delete(state.warm_pool, container_id)

        active_containers =
          Map.put(state.active_containers, container_id, Map.put(container_info, :client, from))

        state = %{state | warm_pool: warm_pool, active_containers: active_containers}

        ContainerMetrics.record_container_checkout(container_id)
        Logger.debug("Container #{container_id} checked out from warm pool")

        {:reply, {:ok, container_info}, state}

      {:error, :no_warm_containers} ->
        # Try to provision new container
        case provision_new_container(state) do
          {:ok, container_id, container_info} ->
            active_containers =
              Map.put(
                state.active_containers,
                container_id,
                Map.put(container_info, :client, from)
              )

            state = %{state | active_containers: active_containers}

            ContainerMetrics.record_container_provision(container_id)
            Logger.info("New container #{container_id} provisioned")

            {:reply, {:ok, container_info}, state}

          {:error, reason} ->
            Logger.error("Failed to provision new container: #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:get_pool_status, _from, state) do
    status = %{
      warm_pool_size: map_size(state.warm_pool),
      active_containers: map_size(state.active_containers),
      total_containers: map_size(state.warm_pool) + map_size(state.active_containers),
      pool_config: state.pool_config
    }

    {:reply, status, state}
  end

  def handle_cast({:return_container, container_id}, state) do
    case Map.pop(state.active_containers, container_id) do
      {nil, _} ->
        Logger.warning("Attempted to return unknown container: #{container_id}")
        {:noreply, state}

      {container_info, active_containers} ->
        state = process_returned_container(container_id, container_info, active_containers, state)
        {:noreply, state}
    end
  end

  def handle_cast({:terminate_container, container_id, reason}, state) do
    # Remove from both pools and terminate
    warm_pool = Map.delete(state.warm_pool, container_id)
    active_containers = Map.delete(state.active_containers, container_id)

    terminate_container_impl(container_id, reason)

    state = %{state | warm_pool: warm_pool, active_containers: active_containers}
    {:noreply, state}
  end

  def handle_info(:ensure_warm_pool, state) do
    state = ensure_warm_pool_size(state)
    schedule_warm_pool_maintenance()
    {:noreply, state}
  end

  def handle_info(:cleanup_idle_containers, state) do
    state = cleanup_idle_containers(state)
    schedule_idle_cleanup()
    {:noreply, state}
  end

  def handle_info({:container_health_changed, container_id, health_status}, state) do
    case health_status do
      :unhealthy ->
        Logger.warning("Container #{container_id} became unhealthy, terminating")
        send(self(), {:terminate_container, container_id, :unhealthy})

      :healthy ->
        Logger.debug("Container #{container_id} health restored")
    end

    {:noreply, state}
  end

  def handle_info(:scale_down_requested, state) do
    Logger.info("Scale down requested, reviewing warm pool")
    # For now, just acknowledge the scale down request
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  defp process_returned_container(container_id, container_info, active_containers, state) do
    case ContainerHealth.check_container(container_id) do
      :healthy ->
        return_healthy_container(container_id, container_info, active_containers, state)

      :unhealthy ->
        terminate_container_impl(container_id, :unhealthy)
        %{state | active_containers: active_containers}
    end
  end

  defp return_healthy_container(container_id, container_info, active_containers, state) do
    if map_size(state.warm_pool) < state.pool_config.max_warm_containers do
      container_info =
        container_info
        |> Map.delete(:client)
        |> Map.put(:returned_at, System.system_time(:millisecond))

      warm_pool = Map.put(state.warm_pool, container_id, container_info)

      ContainerMetrics.record_container_return(container_id)
      Logger.debug("Container #{container_id} returned to warm pool")

      %{state | warm_pool: warm_pool, active_containers: active_containers}
    else
      terminate_container_impl(container_id, :pool_full)
      %{state | active_containers: active_containers}
    end
  end

  defp merge_default_config(config) do
    Map.merge(@default_pool_config, config)
  end

  defp ensure_backend_defaults(config) do
    defaults = %{
      container_prefix: "flame-worker",
      dns_domain: "flame.local",
      image: "flame-worker:latest",
      erlang_cookie: "flame_cookie_#{:rand.uniform(999_999)}"
    }

    Map.merge(defaults, config)
  end

  defp find_available_warm_container(state) do
    case Enum.find(state.warm_pool, fn {_id, info} ->
           ContainerHealth.check_container(info.container_name) == :healthy
         end) do
      {container_id, container_info} -> {:ok, container_id, container_info}
      nil -> {:error, :no_warm_containers}
    end
  end

  defp provision_new_container(state) do
    if map_size(state.active_containers) >= state.pool_config.max_active_containers do
      {:error, :max_active_containers_reached}
    else
      container_name = generate_container_name(state.backend_config)
      node_name = "#{container_name}@#{container_name}.#{state.backend_config.dns_domain}"

      with {:ok, _} <- start_container(state.backend_config, container_name, node_name),
           {:ok, _} <- wait_for_readiness(container_name),
           {:ok, _} <- establish_connection(node_name) do
        container_info = %{
          container_id: container_name,
          container_name: container_name,
          node_name: String.to_atom(node_name),
          started_at: System.system_time(:millisecond),
          status: :running,
          provisioned_at: System.system_time(:millisecond)
        }

        {:ok, container_name, container_info}
      else
        error ->
          cleanup_container(container_name)
          error
      end
    end
  end

  defp ensure_warm_pool_size(state) do
    current_warm_size = map_size(state.warm_pool)
    min_warm = state.pool_config.min_warm_containers

    if current_warm_size < min_warm do
      containers_to_provision = min_warm - current_warm_size
      Logger.info("Provisioning #{containers_to_provision} containers for warm pool")

      warm_pool =
        Enum.reduce(1..containers_to_provision, state.warm_pool, fn _, acc ->
          provision_and_add_warm_container(state, acc)
        end)

      %{state | warm_pool: warm_pool}
    else
      state
    end
  end

  defp provision_and_add_warm_container(state, warm_pool_acc) do
    case provision_new_container(state) do
      {:ok, container_id, container_info} ->
        container_info =
          Map.put(container_info, :warmed_at, System.system_time(:millisecond))

        Map.put(warm_pool_acc, container_id, container_info)

      {:error, reason} ->
        Logger.error("Failed to provision warm container: #{inspect(reason)}")
        warm_pool_acc
    end
  end

  defp cleanup_idle_containers(state) do
    current_time = System.system_time(:millisecond)
    idle_timeout = state.pool_config.container_idle_timeout

    {idle_containers, active_warm_pool} =
      Enum.split_with(state.warm_pool, fn {_id, info} ->
        case Map.get(info, :returned_at) do
          nil -> false
          returned_at -> current_time - returned_at > idle_timeout
        end
      end)

    # Terminate idle containers
    Enum.each(idle_containers, fn {container_id, _info} ->
      Logger.info("Terminating idle container: #{container_id}")
      terminate_container_impl(container_id, :idle_timeout)
    end)

    warm_pool = Map.new(active_warm_pool)
    %{state | warm_pool: warm_pool}
  end

  defp terminate_container_impl(container_id, reason) do
    ContainerMetrics.record_container_termination(container_id, reason)
    cleanup_container(container_id)
  end

  defp schedule_warm_pool_maintenance do
    Process.send_after(self(), :ensure_warm_pool, 60_000)
  end

  defp schedule_idle_cleanup do
    Process.send_after(self(), :cleanup_idle_containers, 300_000)
  end

  # Helper functions borrowed from backend implementation
  defp generate_container_name(config) do
    timestamp = System.system_time(:millisecond)
    random = :rand.uniform(999)
    "#{config.container_prefix}-#{timestamp}-#{random}"
  end

  defp start_container(config, container_name, node_name) do
    env_vars = [
      "--env",
      "NODE_NAME=#{node_name}",
      "--env",
      "ERLANG_COOKIE=#{config.erlang_cookie}"
    ]

    cmd =
      [
        "container",
        "run",
        "--name",
        container_name,
        "--detach",
        "--rm"
      ] ++ env_vars ++ [config.image]

    case System.cmd("container", tl(cmd)) do
      {output, 0} ->
        Logger.info("Started container #{container_name}")
        {:ok, String.trim(output)}

      {error, code} ->
        Logger.error("Failed to start container #{container_name}: #{error}")
        {:error, {:container_start_failed, code, error}}
    end
  end

  defp wait_for_readiness(container_name, timeout \\ 30_000) do
    start_time = System.system_time(:millisecond)
    check_readiness = fn -> check_epmd_readiness(container_name) end
    wait_loop(check_readiness, start_time, timeout)
  end

  defp check_epmd_readiness(container_name) do
    case System.cmd("container", ["exec", container_name, "epmd", "-names"]) do
      {output, 0} ->
        if String.contains?(output, "name "), do: :ready, else: :not_ready

      _ ->
        :not_ready
    end
  end

  defp wait_loop(check_fn, start_time, timeout) do
    current_time = System.system_time(:millisecond)

    if current_time - start_time > timeout do
      {:error, :readiness_timeout}
    else
      case check_fn.() do
        :ready ->
          {:ok, :ready}

        :not_ready ->
          Process.sleep(1000)
          wait_loop(check_fn, start_time, timeout)
      end
    end
  end

  defp establish_connection(node_name) do
    node_atom = String.to_atom(node_name)

    case Node.connect(node_atom) do
      true ->
        Logger.info("Connected to node #{node_name}")
        {:ok, node_atom}

      false ->
        Logger.error("Failed to connect to node #{node_name}")
        {:error, {:connection_failed, node_name}}
    end
  end

  defp cleanup_container(container_name) do
    case System.cmd("container", ["stop", container_name]) do
      {_, 0} -> :ok
      _ -> :error
    end
  end
end
