defmodule FLAME.ResourceManager do
  @moduledoc """
  Resource management system for Apple Containers FLAME backend.

  Provides:
  - Container resource limit configuration and enforcement
  - Memory usage monitoring and cleanup
  - Automatic scaling based on resource utilization
  - Resource quota management
  """

  use GenServer
  require Logger

  alias FLAME.AppleContainers.CLI

  defstruct [
    :resource_config,
    :container_resources,
    :global_limits,
    :scaling_config,
    :monitoring_interval
  ]

  @default_config %{
    global_limits: %{
      # 8 GB total
      max_total_memory_gb: 8,
      # 4 CPU cores
      max_total_cpu_cores: 4,
      # 20 containers max
      max_concurrent_containers: 20
    },
    container_limits: %{
      # 512 MB per container
      memory_mb: 512,
      # 50% CPU per container
      cpu_percent: 50,
      # 1 GB disk per container
      disk_mb: 1024,
      # 100 Mbps network
      network_bandwidth_mbps: 100
    },
    scaling_config: %{
      # Scale up at 80% utilization
      scale_up_threshold: 0.8,
      # Scale down at 30% utilization
      scale_down_threshold: 0.3,
      # Minimum containers
      min_containers: 2,
      # Maximum containers
      max_containers: 10,
      # 5 minutes cooldown
      cooldown_period: 300_000
    },
    # 30 seconds
    monitoring_interval: 30_000
  }

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init(opts) do
    clean_opts = if is_list(opts), do: Keyword.delete(opts, :name), else: opts
    config = Keyword.get(clean_opts, :config, %{}) |> merge_default_config()

    state = %__MODULE__{
      resource_config: config,
      container_resources: %{},
      global_limits: config.global_limits,
      scaling_config: config.scaling_config,
      monitoring_interval: config.monitoring_interval
    }

    # Start resource monitoring
    schedule_resource_monitoring(state.monitoring_interval)

    Logger.info("Resource manager initialized with limits: #{inspect(config.global_limits)}")
    {:ok, state}
  end

  def register_container(container_id, resource_config \\ %{}, server \\ __MODULE__) do
    GenServer.cast(server, {:register_container, container_id, resource_config})
  end

  def unregister_container(container_id, server \\ __MODULE__) do
    GenServer.cast(server, {:unregister_container, container_id})
  end

  def check_resource_availability(resource_requirements, server \\ __MODULE__) do
    GenServer.call(server, {:check_resource_availability, resource_requirements})
  end

  def get_resource_status(server \\ __MODULE__) do
    GenServer.call(server, :get_resource_status)
  end

  def get_container_resources(container_id, server \\ __MODULE__) do
    GenServer.call(server, {:get_container_resources, container_id})
  end

  def enforce_container_limits(container_id, server \\ __MODULE__) do
    GenServer.call(server, {:enforce_container_limits, container_id})
  end

  def trigger_scaling_check(server \\ __MODULE__) do
    GenServer.cast(server, :trigger_scaling_check)
  end

  # GenServer callbacks

  def handle_cast({:register_container, container_id, resource_config}, state) do
    default_limits = state.resource_config.container_limits
    container_limits = Map.merge(default_limits, resource_config)

    container_info = %{
      container_id: container_id,
      limits: container_limits,
      current_usage: %{},
      registered_at: System.system_time(:millisecond),
      last_monitored: nil
    }

    container_resources = Map.put(state.container_resources, container_id, container_info)
    state = %{state | container_resources: container_resources}

    Logger.info("Registered container #{container_id} with limits: #{inspect(container_limits)}")
    {:noreply, state}
  end

  def handle_cast({:unregister_container, container_id}, state) do
    container_resources = Map.delete(state.container_resources, container_id)
    state = %{state | container_resources: container_resources}

    Logger.info("Unregistered container #{container_id}")
    {:noreply, state}
  end

  def handle_cast(:trigger_scaling_check, state) do
    state = perform_scaling_check(state)
    {:noreply, state}
  end

  def handle_call({:check_resource_availability, requirements}, _from, state) do
    availability = check_global_resource_availability(requirements, state)
    {:reply, availability, state}
  end

  def handle_call(:get_resource_status, _from, state) do
    status = generate_resource_status(state)
    {:reply, status, state}
  end

  def handle_call({:get_container_resources, container_id}, _from, state) do
    case Map.get(state.container_resources, container_id) do
      nil -> {:reply, {:error, :not_found}, state}
      container_info -> {:reply, {:ok, container_info}, state}
    end
  end

  def handle_call({:enforce_container_limits, container_id}, _from, state) do
    case Map.get(state.container_resources, container_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      container_info ->
        result = enforce_limits(container_id, container_info)
        {:reply, result, state}
    end
  end

  def handle_info(:monitor_resources, state) do
    state = monitor_all_containers(state)
    state = perform_scaling_check(state)
    schedule_resource_monitoring(state.monitoring_interval)
    {:noreply, state}
  end

  # Private functions

  defp merge_default_config(config) do
    Map.merge(@default_config, config)
  end

  defp schedule_resource_monitoring(interval) do
    Process.send_after(self(), :monitor_resources, interval)
  end

  defp check_global_resource_availability(requirements, state) do
    current_usage = calculate_total_resource_usage(state)
    required = requirements

    memory_available =
      current_usage.memory_gb + required.memory_gb <= state.global_limits.max_total_memory_gb

    cpu_available =
      current_usage.cpu_cores + required.cpu_cores <= state.global_limits.max_total_cpu_cores

    container_slots_available =
      current_usage.container_count < state.global_limits.max_concurrent_containers

    if memory_available and cpu_available and container_slots_available do
      :available
    else
      reasons = []
      reasons = if memory_available, do: reasons, else: [:memory_limit | reasons]
      reasons = if cpu_available, do: reasons, else: [:cpu_limit | reasons]
      reasons = if container_slots_available, do: reasons, else: [:container_limit | reasons]

      {:unavailable, reasons}
    end
  end

  defp calculate_total_resource_usage(state) do
    Enum.reduce(
      state.container_resources,
      %{memory_gb: 0, cpu_cores: 0, container_count: 0},
      fn {_id, container_info}, acc ->
        memory_gb = (container_info.limits.memory_mb || 0) / 1024
        cpu_cores = (container_info.limits.cpu_percent || 0) / 100

        %{
          memory_gb: acc.memory_gb + memory_gb,
          cpu_cores: acc.cpu_cores + cpu_cores,
          container_count: acc.container_count + 1
        }
      end
    )
  end

  defp monitor_all_containers(state) do
    current_time = System.system_time(:millisecond)

    container_resources =
      Enum.reduce(state.container_resources, %{}, fn {container_id, container_info}, acc ->
        updated_info = monitor_container_resources(container_id, container_info, current_time)
        Map.put(acc, container_id, updated_info)
      end)

    %{state | container_resources: container_resources}
  end

  defp monitor_container_resources(container_id, container_info, current_time) do
    current_usage = get_container_resource_usage(container_id)

    updated_info = %{container_info | current_usage: current_usage, last_monitored: current_time}

    # Check for limit violations
    check_limit_violations(container_id, updated_info)

    updated_info
  end

  defp get_container_resource_usage(container_id) do
    # This would integrate with actual container monitoring
    # For now, return mock data
    # Try to get actual container stats
    case CLI.adapter().get_container_stats(container_id, ["--format", "json"]) do
      {output, 0} ->
        parse_container_stats(output)

      {_, _} ->
        # Container might not be running, return zero usage
        %{memory_mb: 0, cpu_percent: 0, disk_mb: 0, network_mbps: 0}
    end
  rescue
    _ ->
      # Fallback to zero usage if monitoring fails
      %{memory_mb: 0, cpu_percent: 0, disk_mb: 0, network_mbps: 0}
  end

  defp parse_container_stats(json_output) do
    # Parse container stats JSON - this would be more sophisticated in practice
    stats = Jason.decode!(json_output)

    %{
      memory_mb: get_in(stats, ["memory", "usage"]) || 0,
      cpu_percent: get_in(stats, ["cpu", "percent"]) || 0,
      disk_mb: get_in(stats, ["disk", "usage"]) || 0,
      network_mbps: get_in(stats, ["network", "bandwidth"]) || 0
    }
  rescue
    _ ->
      %{memory_mb: 0, cpu_percent: 0, disk_mb: 0, network_mbps: 0}
  end

  defp check_limit_violations(container_id, container_info) do
    usage = container_info.current_usage
    limits = container_info.limits

    violations = []

    violations =
      if usage.memory_mb > limits.memory_mb do
        Logger.warning(
          "Container #{container_id} memory usage #{usage.memory_mb}MB exceeds limit #{limits.memory_mb}MB"
        )

        [:memory | violations]
      else
        violations
      end

    violations =
      if usage.cpu_percent > limits.cpu_percent do
        Logger.warning(
          "Container #{container_id} CPU usage #{usage.cpu_percent}% exceeds limit #{limits.cpu_percent}%"
        )

        [:cpu | violations]
      else
        violations
      end

    violations =
      if usage.disk_mb > limits.disk_mb do
        Logger.warning(
          "Container #{container_id} disk usage #{usage.disk_mb}MB exceeds limit #{limits.disk_mb}MB"
        )

        [:disk | violations]
      else
        violations
      end

    if violations != [] do
      # Trigger enforcement action
      spawn(fn -> enforce_limits(container_id, container_info) end)
    end
  end

  defp enforce_limits(container_id, container_info) do
    usage = container_info.current_usage
    limits = container_info.limits

    # Enforce memory limits
    if usage.memory_mb > limits.memory_mb do
      enforce_memory_limit(container_id, limits.memory_mb)
    end

    # Enforce CPU limits
    if usage.cpu_percent > limits.cpu_percent do
      enforce_cpu_limit(container_id, limits.cpu_percent)
    end

    # Enforce disk limits
    if usage.disk_mb > limits.disk_mb do
      enforce_disk_limit(container_id, limits.disk_mb)
    end

    :ok
  end

  defp enforce_memory_limit(container_id, limit_mb) do
    # In a real implementation, this would use container resource controls
    Logger.info("Enforcing memory limit #{limit_mb}MB for container #{container_id}")

    # Example: update container memory limit
    case CLI.adapter().update_container(["--memory", "#{limit_mb}m", container_id]) do
      {_, 0} ->
        Logger.info("Successfully updated memory limit for #{container_id}")
        :ok

      {error, _} ->
        Logger.error("Failed to update memory limit for #{container_id}: #{error}")
        :error
    end
  end

  defp enforce_cpu_limit(container_id, limit_percent) do
    Logger.info("Enforcing CPU limit #{limit_percent}% for container #{container_id}")

    # Example: update container CPU limit
    case CLI.adapter().update_container(["--cpus", "#{limit_percent / 100}", container_id]) do
      {_, 0} ->
        Logger.info("Successfully updated CPU limit for #{container_id}")
        :ok

      {error, _} ->
        Logger.error("Failed to update CPU limit for #{container_id}: #{error}")
        :error
    end
  end

  defp enforce_disk_limit(container_id, limit_mb) do
    Logger.info("Enforcing disk limit #{limit_mb}MB for container #{container_id}")
    # Disk limits are typically set at container creation time
    # Log the violation for now
    :ok
  end

  defp perform_scaling_check(state) do
    current_usage = calculate_total_resource_usage(state)
    total_utilization = calculate_utilization_percentage(current_usage, state.global_limits)

    cond do
      total_utilization > state.scaling_config.scale_up_threshold ->
        trigger_scale_up(state, total_utilization)

      total_utilization < state.scaling_config.scale_down_threshold ->
        trigger_scale_down(state, total_utilization)

      true ->
        state
    end
  end

  defp calculate_utilization_percentage(usage, limits) do
    memory_util = usage.memory_gb / limits.max_total_memory_gb
    cpu_util = usage.cpu_cores / limits.max_total_cpu_cores
    container_util = usage.container_count / limits.max_concurrent_containers

    max(memory_util, max(cpu_util, container_util))
  end

  defp trigger_scale_up(state, utilization) do
    Logger.info(
      "High resource utilization detected (#{Float.round(utilization * 100, 1)}%), considering scale up"
    )

    # Notify container pool to provision more warm containers
    send(FLAME.ContainerPool, :scale_up_requested)

    state
  end

  defp trigger_scale_down(state, utilization) do
    Logger.info(
      "Low resource utilization detected (#{Float.round(utilization * 100, 1)}%), considering scale down"
    )

    # Container pool is disabled, skip scaling notification
    # send(FLAME.ContainerPool, :scale_down_requested)

    state
  end

  defp generate_resource_status(state) do
    current_usage = calculate_total_resource_usage(state)
    utilization = calculate_utilization_percentage(current_usage, state.global_limits)

    %{
      current_usage: current_usage,
      global_limits: state.global_limits,
      utilization_percentage: Float.round(utilization * 100, 1),
      container_count: map_size(state.container_resources),
      scaling_config: state.scaling_config,
      last_monitored: System.system_time(:millisecond)
    }
  end
end
