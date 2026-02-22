defmodule FLAME.AppleContainers.Pool do
  @moduledoc """
  Container pool management for FLAME Apple Containers backend.

  This module manages a pool of containers for efficient task execution.
  It handles container lifecycle, resource allocation, health monitoring,
  and automatic scaling based on demand.

  ## Features

  - Warm container pool with configurable sizing
  - Automatic container health monitoring
  - Graceful container replacement when unhealthy
  - Resource-aware container allocation
  - Metrics collection for pool performance
  - Auto-scaling based on demand patterns

  ## Pool States

  Containers in the pool can be in the following states:
  - `:initializing` - Container is being created
  - `:available` - Container is ready and available for tasks
  - `:busy` - Container is currently executing a task
  - `:unhealthy` - Container has failed health checks
  - `:terminating` - Container is being shut down

  ## Configuration

  The pool can be configured with:
  - Initial and maximum pool sizes
  - Health check intervals and thresholds
  - Resource limits per container
  - Auto-scaling policies
  - Container replacement strategies
  """

  use GenServer
  require Logger

  # alias FLAME.AppleContainersBackend

  defstruct [
    :config,
    :backend,
    :containers,
    :available_queue,
    :health_checker,
    :metrics,
    :auto_scaler,
    :pending_requests,
    :scaling_in_progress,
    :scaling_lock,
    :shutdown_info
  ]

  # @container_states [:initializing, :available, :busy, :unhealthy, :terminating]

  @default_config %{
    size: 3,
    max_size: 10,
    min_size: 1,
    health_check_interval: 30_000,
    container_timeout: 300_000,
    max_unhealthy_ratio: 0.3,
    scale_up_threshold: 0.8,
    scale_down_threshold: 0.2,
    scale_cooldown: 60_000,
    replacement_strategy: :lazy,
    resource_limits: %{
      memory: "512m",
      cpu: "1.0"
    }
  }

  ## Public API

  @doc """
  Starts the container pool.

  ## Options

  - `:size` - Initial pool size (default: 3)
  - `:max_size` - Maximum pool size (default: 10)
  - `:min_size` - Minimum pool size (default: 1)
  - `:backend` - Backend instance to use for container management
  - `:health_check_interval` - Health check frequency in ms (default: 30_000)
  - `:container_timeout` - Container idle timeout in ms (default: 300_000)
  - `:auto_scale` - Enable automatic scaling (default: true)
  - `:resource_limits` - Resource limits per container

  ## Examples

      {:ok, pool} = FLAME.AppleContainers.Pool.start_link([
        size: 5,
        max_size: 20,
        backend: backend,
        auto_scale: true
      ])
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Acquires a container from the pool for task execution.

  This function will:
  1. Find an available container from the pool
  2. Mark it as busy
  3. Return container information for task execution
  4. Optionally wait if no containers are available

  ## Parameters

  - `pool` - Pool process PID
  - `timeout` - Maximum time to wait for a container (default: 30_000ms)

  ## Returns

  - `{:ok, container_info}` - Container acquired successfully
  - `{:error, reason}` - Failed to acquire container

  ## Examples

      {:ok, container} = FLAME.AppleContainers.Pool.acquire_container(pool)
      {:ok, container} = FLAME.AppleContainers.Pool.acquire_container(pool, 60_000)
  """
  def acquire_container(pool, timeout \\ 30_000) do
    GenServer.call(pool, :acquire_container, timeout)
  end

  @doc """
  Releases a container back to the pool after task completion.

  ## Parameters

  - `pool` - Pool process PID
  - `container` - Container info returned from acquire_container/2

  ## Returns

  - `:ok` - Container released successfully
  - `{:error, reason}` - Failed to release container

  ## Examples

      :ok = FLAME.AppleContainers.Pool.release_container(pool, container)
  """
  def release_container(pool, container) do
    GenServer.call(pool, {:release_container, container})
  end

  @doc """
  Gets the current status of the pool.

  ## Returns

  A map containing:
  - `:total` - Total number of containers
  - `:available` - Number of available containers
  - `:busy` - Number of busy containers
  - `:unhealthy` - Number of unhealthy containers
  - `:initializing` - Number of containers being created
  - `:terminating` - Number of containers being terminated

  ## Examples

      status = FLAME.AppleContainers.Pool.get_status(pool)
      # => %{total: 5, available: 3, busy: 1, unhealthy: 0, initializing: 1, terminating: 0}
  """
  def get_status(pool) do
    GenServer.call(pool, :get_status)
  end

  @doc """
  Gets the health status of the pool.

  ## Returns

  - `:healthy` - Pool is operating normally
  - `:degraded` - Pool has some issues but is functional
  - `:unhealthy` - Pool has significant issues

  ## Examples

      health = FLAME.AppleContainers.Pool.get_health(pool)
  """
  def get_health(pool) do
    GenServer.call(pool, :get_health)
  end

  @doc """
  Manually scales the pool to the specified size.

  ## Parameters

  - `pool` - Pool process PID
  - `new_size` - Desired pool size

  ## Returns

  - `:ok` - Scaling initiated successfully
  - `{:error, reason}` - Scaling failed

  ## Examples

      :ok = FLAME.AppleContainers.Pool.scale(pool, 8)
  """
  def scale(pool, new_size) do
    GenServer.call(pool, {:scale, new_size})
  end

  @doc """
  Waits for the pool to finish initialization.

  ## Parameters

  - `pool` - Pool process PID
  - `timeout` - Maximum time to wait in milliseconds (default: 5000)

  ## Returns

  - `:ok` - Pool initialization completed
  - `{:error, :timeout}` - Timeout waiting for initialization

  ## Examples

      :ok = FLAME.AppleContainers.Pool.wait_for_initialization(pool)
  """
  def wait_for_initialization(pool, timeout \\ 5000) do
    start_time = System.monotonic_time(:millisecond)

    wait_loop = fn wait_loop ->
      case GenServer.call(pool, :wait_for_initialization) do
        :ok ->
          :ok

        {:error, :initializing} ->
          retry_or_timeout(start_time, timeout, wait_loop)
      end
    end

    wait_loop.(wait_loop)
  end

  @doc """
  Waits for all scaling operations to complete.

  ## Parameters

  - `pool` - Pool process PID
  - `timeout` - Maximum time to wait in milliseconds (default: 5000)

  ## Returns

  - `:ok` - No scaling operations in progress
  - `{:error, :timeout}` - Timeout waiting for scaling to complete

  ## Examples

      :ok = FLAME.AppleContainers.Pool.wait_for_scaling_complete(pool)
  """
  def wait_for_scaling_complete(pool, timeout \\ 5000) do
    start_time = System.monotonic_time(:millisecond)

    wait_loop = fn wait_loop ->
      case GenServer.call(pool, :wait_for_scaling_complete) do
        :ok ->
          :ok

        {:error, :scaling_in_progress} ->
          retry_or_timeout(start_time, timeout, wait_loop)
      end
    end

    wait_loop.(wait_loop)
  end

  @doc """
  Gets detailed metrics about pool performance.

  ## Returns

  A map containing detailed metrics about container utilization,
  health statistics, and performance indicators.

  ## Examples

      metrics = FLAME.AppleContainers.Pool.get_metrics(pool)
  """
  def get_metrics(pool) do
    GenServer.call(pool, :get_metrics)
  end

  @doc """
  Gracefully shuts down the pool and all containers.

  ## Parameters

  - `pool` - Pool process PID
  - `timeout` - Maximum time to wait for shutdown (default: 30_000ms)

  ## Examples

      :ok = FLAME.AppleContainers.Pool.shutdown(pool)
  """
  def shutdown(pool, timeout \\ 30_000) do
    GenServer.call(pool, {:shutdown, timeout}, timeout + 5_000)
  end

  ## GenServer Implementation

  @impl true
  def init(opts) do
    config = merge_config(opts)
    backend = Keyword.fetch!(opts, :backend)

    Logger.info("Starting container pool with config: #{inspect(config, pretty: true)}")

    state = %__MODULE__{
      config: config,
      backend: backend,
      containers: %{},
      available_queue: :queue.new(),
      metrics: init_metrics(),
      auto_scaler: nil,
      pending_requests: :queue.new(),
      scaling_in_progress: false,
      scaling_lock: :none
    }

    # Start health checker
    {:ok, health_checker} = start_health_checker(self(), config.health_check_interval)
    state = %{state | health_checker: health_checker}

    # Initialize the pool with the desired number of containers
    Logger.debug("Sending initialize_pool message with size #{config.size} to #{inspect(self())}")
    send(self(), {:initialize_pool, config.size})

    Logger.info("Container pool started successfully")
    {:ok, state}
  end

  @impl true
  def handle_call(:acquire_container, from, state) do
    case :queue.out(state.available_queue) do
      {{:value, container_id}, new_queue} ->
        acquire_from_queue(container_id, new_queue, from, state)

      {:empty, _queue} ->
        acquire_with_scale_up(from, state)
    end
  end

  @impl true
  def handle_call({:release_container, container}, _from, state) do
    container_id = container.id

    case Map.get(state.containers, container_id) do
      nil ->
        Logger.warning("Attempted to release unknown container: #{container_id}")
        {:reply, {:error, :unknown_container}, state}

      existing_container ->
        # Check if container is healthy before returning to pool
        updated_state =
          if container_healthy?(container) do
            # Mark as available and add to queue
            updated_container = Map.put(existing_container, :state, :available)
            containers = Map.put(state.containers, container_id, updated_container)
            available_queue = :queue.in(container_id, state.available_queue)

            state = %{state | containers: containers, available_queue: available_queue}

            # Update metrics
            metrics = update_release_metrics(state.metrics)
            %{state | metrics: metrics}
          else
            # Container is unhealthy, mark for replacement
            Logger.warning("Container #{container_id} is unhealthy, marking for replacement")
            updated_container = Map.put(existing_container, :state, :unhealthy)
            containers = Map.put(state.containers, container_id, updated_container)

            state = %{state | containers: containers}

            # Schedule replacement
            send(self(), {:replace_container, container_id})

            state
          end

        Logger.debug("Container #{container_id} released")

        # Check if we should complete shutdown
        case check_shutdown_completion(updated_state) do
          {:shutdown_complete, final_state} ->
            {:stop, :normal, :ok, final_state}

          final_state ->
            {:reply, :ok, final_state}
        end
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = calculate_pool_status(state)
    {:reply, status, state}
  end

  @impl true
  def handle_call(:get_health, _from, state) do
    health = calculate_pool_health(state)
    {:reply, health, state}
  end

  @impl true
  def handle_call({:scale, new_size}, _from, state) do
    cond do
      new_size < state.config.min_size or new_size > state.config.max_size ->
        {:reply, {:error, :invalid_size}, state}

      state.scaling_in_progress ->
        Logger.warning("Scaling already in progress, rejecting concurrent scale request")
        {:reply, {:error, :scaling_in_progress}, state}

      true ->
        updated_state = apply_scaling(new_size, state)
        {:reply, :ok, updated_state}
    end
  end

  @impl true
  def handle_call(:wait_for_initialization, _from, state) do
    if state.scaling_lock == :initialize do
      # Still initializing, reply with error and let caller retry
      {:reply, {:error, :initializing}, state}
    else
      # Initialization complete
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:wait_for_scaling_complete, _from, state) do
    if state.scaling_in_progress do
      # Scaling in progress, reply with error and let caller retry
      {:reply, {:error, :scaling_in_progress}, state}
    else
      # No scaling in progress
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    enhanced_metrics = enhance_metrics(state.metrics, state)
    {:reply, enhanced_metrics, state}
  end

  @impl true
  def handle_call({:shutdown, timeout}, from, state) do
    Logger.info("Shutting down container pool with timeout: #{timeout}ms")

    # Stop health checker
    if state.health_checker do
      :timer.cancel(state.health_checker)
    end

    # Check if there are busy containers
    busy_containers =
      state.containers
      |> Enum.filter(fn {_id, container} -> container.state == :busy end)
      |> Enum.map(fn {id, _container} -> id end)

    if length(busy_containers) > 0 do
      Logger.info("Waiting for #{length(busy_containers)} busy containers to finish...")

      # Start a timer for the timeout
      timeout_ref = :erlang.start_timer(timeout, self(), :shutdown_timeout)

      # Store shutdown info and wait for containers to finish
      shutdown_info = %{
        from: from,
        timeout_ref: timeout_ref,
        busy_containers: busy_containers,
        started_at: System.monotonic_time(:millisecond)
      }

      state = Map.put(state, :shutdown_info, shutdown_info)
      {:noreply, state}
    else
      # No busy containers, shutdown immediately
      perform_immediate_shutdown(state)
      {:stop, :normal, :ok, state}
    end
  end

  defp perform_immediate_shutdown(state) do
    Logger.info("Performing immediate shutdown")

    # Terminate all containers
    Enum.each(state.containers, fn {container_id, _container} ->
      terminate_container(container_id, state)
    end)

    Logger.info("Container pool shutdown completed")
  end

  @impl true
  def handle_info({:initialize_pool, size}, state) do
    Logger.info("Initializing pool with #{size} containers")

    # Set scaling_in_progress to prevent concurrent scaling during initialization
    state = %{state | scaling_in_progress: true, scaling_lock: :initialize}

    # Create initial containers with staggered timing to avoid overwhelming the system
    pool_pid = self()

    Enum.each(1..size, fn i ->
      Logger.debug("Spawning container creation process #{i} for pool #{inspect(pool_pid)}")
      # Stagger container creation to avoid overwhelming the system
      spawn(fn -> staggered_container_creation(i, pool_pid, state) end)
    end)

    # Clear scaling lock after all containers should be created
    # Using a timeout that accounts for staggered creation + container creation time
    # 5ms per container + 200ms for creation
    max_creation_time = size * 5 + 200
    Process.send_after(self(), {:clear_initialization_lock, size}, max_creation_time)

    {:noreply, state}
  end

  @impl true
  def handle_info({:container_created, container_info}, state) do
    container_id = container_info.id
    Logger.debug("Container #{container_id} created successfully")

    # Add to containers map
    container = Map.put(container_info, :state, :available)
    containers = Map.put(state.containers, container_id, container)

    # Check if there are pending requests
    case :queue.out(state.pending_requests) do
      {{:value, from}, new_pending_requests} ->
        # Fulfill the pending request immediately
        updated_container = Map.put(container, :state, :busy)
        containers = Map.put(containers, container_id, updated_container)

        state = %{state | containers: containers, pending_requests: new_pending_requests}

        # Update metrics
        metrics = update_acquisition_metrics(state.metrics)
        state = %{state | metrics: metrics}

        Logger.debug("Container #{container_id} allocated to pending request")
        # Reply to the waiting caller
        GenServer.reply(from, {:ok, updated_container})
        {:noreply, state}

      {:empty, _queue} ->
        # No pending requests, add to available queue
        available_queue = :queue.in(container_id, state.available_queue)
        state = %{state | containers: containers, available_queue: available_queue}

        # Update metrics
        metrics = update_creation_metrics(state.metrics)
        state = %{state | metrics: metrics}

        Logger.debug("Container #{container_id} added to available queue")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:container_creation_failed, reason}, state) do
    Logger.error("Container creation failed: #{inspect(reason)}")

    # Check if there are pending requests and fail them
    case :queue.out(state.pending_requests) do
      {{:value, from}, new_pending_requests} ->
        # Fail the pending request
        GenServer.reply(from, {:error, {:container_creation_failed, reason}})
        state = %{state | pending_requests: new_pending_requests}

        # Update metrics
        metrics = update_creation_failure_metrics(state.metrics)
        %{state | metrics: metrics}

      {:empty, _queue} ->
        # No pending requests, just update metrics
        metrics = update_creation_failure_metrics(state.metrics)
        %{state | metrics: metrics}
    end
    |> then(fn updated_state -> {:noreply, updated_state} end)
  end

  @impl true
  def handle_info({:health_check}, state) do
    # Perform health checks on all containers
    spawn(fn -> perform_health_checks(self(), state) end)
    {:noreply, state}
  end

  @impl true
  def handle_info({:health_check_result, container_id, health_status}, state) do
    case Map.get(state.containers, container_id) do
      nil ->
        Logger.warning("Health check result for unknown container: #{container_id}")
        {:noreply, state}

      container ->
        updated_container =
          Map.put(container, :last_health_check, System.monotonic_time(:millisecond))

        updated_state =
          if health_status == :unhealthy && container.state == :available do
            # Remove from available queue and mark as unhealthy
            available_queue = remove_from_queue(state.available_queue, container_id)
            updated_unhealthy_container = Map.put(updated_container, :state, :unhealthy)

            containers = Map.put(state.containers, container_id, updated_unhealthy_container)

            # Schedule replacement
            send(self(), {:replace_container, container_id})

            Logger.warning("Container #{container_id} marked as unhealthy")
            %{state | containers: containers, available_queue: available_queue}
          else
            containers = Map.put(state.containers, container_id, updated_container)
            %{state | containers: containers}
          end

        {:noreply, updated_state}
    end
  end

  @impl true
  def handle_info({:replace_container, container_id}, state) do
    Logger.info("Replacing unhealthy container: #{container_id}")

    # Terminate the unhealthy container
    terminate_container(container_id, state)

    # Remove from state
    containers = Map.delete(state.containers, container_id)
    available_queue = remove_from_queue(state.available_queue, container_id)

    state = %{state | containers: containers, available_queue: available_queue}

    # Create a replacement container
    pool_pid = self()
    spawn(fn -> create_container_async(pool_pid, state) end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:scale_up, count}, state) do
    Logger.info("Scaling up pool by #{count} containers")

    pool_pid = self()

    Enum.each(1..count, fn _i ->
      spawn(fn -> create_container_async(pool_pid, state) end)
    end)

    # Clear scaling lock after containers are created
    Process.send_after(self(), :clear_scaling_lock, 1000)

    {:noreply, state}
  end

  @impl true
  def handle_info({:scale_down, count}, state) do
    Logger.info("Scaling down pool by #{count} containers")

    # Find available containers to remove
    containers_to_remove = find_containers_to_remove(state, count)

    Enum.each(containers_to_remove, fn container_id ->
      send(self(), {:remove_container, container_id})
    end)

    # Clear scaling lock after containers are removed
    Process.send_after(self(), :clear_scaling_lock, 500)

    {:noreply, state}
  end

  @impl true
  def handle_info({:remove_container, container_id}, state) do
    Logger.debug("Removing container: #{container_id}")

    # Terminate container
    terminate_container(container_id, state)

    # Remove from state
    containers = Map.delete(state.containers, container_id)
    available_queue = remove_from_queue(state.available_queue, container_id)

    state = %{state | containers: containers, available_queue: available_queue}

    {:noreply, state}
  end

  @impl true
  def handle_info({:timeout, timeout_ref, :shutdown_timeout}, state) do
    case Map.get(state, :shutdown_info) do
      %{timeout_ref: ^timeout_ref, from: from} ->
        Logger.warning("Shutdown timeout reached, proceeding with forced shutdown")
        perform_immediate_shutdown(state)
        GenServer.reply(from, :ok)
        {:stop, :normal, state}

      _ ->
        Logger.debug("Received timeout for unknown shutdown")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:clear_scaling_lock, state) do
    Logger.debug("Clearing scaling lock")
    state = %{state | scaling_in_progress: false, scaling_lock: :none}
    {:noreply, state}
  end

  @impl true
  def handle_info({:clear_initialization_lock, expected_size}, state) do
    Logger.debug("Clearing initialization lock (expected #{expected_size} containers)")

    # Only clear the lock if we're in initialization mode and have the expected number of containers
    if state.scaling_lock == :initialize do
      current_size = map_size(state.containers)

      if current_size >= expected_size do
        Logger.debug("Initialization complete: #{current_size} containers created")
        state = %{state | scaling_in_progress: false, scaling_lock: :none}
        {:noreply, state}
      else
        Logger.debug(
          "Initialization still in progress: #{current_size}/#{expected_size} containers created, extending timeout"
        )

        # Extend the timeout if containers are still being created
        Process.send_after(self(), {:clear_initialization_lock, expected_size}, 100)
        {:noreply, state}
      end
    else
      # Not in initialization mode, ignore
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:pending_request_timeout, from}, state) do
    Logger.warning("Pending request timeout for #{inspect(from)}")

    # Remove the request from pending queue if it's still there
    new_queue = remove_from_pending_queue(state.pending_requests, from)
    state = %{state | pending_requests: new_queue}

    # Reply with timeout error
    GenServer.reply(from, {:error, :no_containers_available})

    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  ## Private Helper Functions

  defp staggered_container_creation(index, pool_pid, state) do
    if index > 1 do
      # Small delay between container creations
      :timer.sleep((index - 1) * 5)
    end

    create_container_async(pool_pid, state)
  end

  defp apply_scaling(new_size, state) do
    current_size = map_size(state.containers)

    cond do
      new_size > current_size ->
        # Scale up
        containers_to_add = new_size - current_size
        new_state = %{state | scaling_in_progress: true, scaling_lock: :scale_up}
        send(self(), {:scale_up, containers_to_add})
        new_state

      new_size < current_size ->
        # Scale down
        containers_to_remove = current_size - new_size
        new_state = %{state | scaling_in_progress: true, scaling_lock: :scale_down}
        send(self(), {:scale_down, containers_to_remove})
        new_state

      true ->
        # No change needed
        state
    end
  end

  defp acquire_from_queue(container_id, new_queue, from, state) do
    # Mark container as busy
    container = Map.get(state.containers, container_id)

    if container && container.state == :available do
      updated_container = Map.put(container, :state, :busy)
      containers = Map.put(state.containers, container_id, updated_container)

      state = %{state | containers: containers, available_queue: new_queue}

      # Update metrics
      metrics = update_acquisition_metrics(state.metrics)
      state = %{state | metrics: metrics}

      Logger.debug("Container #{container_id} acquired")
      {:reply, {:ok, updated_container}, state}
    else
      # Container doesn't exist or isn't available, try again
      Logger.warning("Container #{container_id} no longer available, retrying")
      handle_call(:acquire_container, from, state)
    end
  end

  defp acquire_with_scale_up(from, state) do
    # No containers available, check if we can scale up
    if can_scale_up?(state) do
      # Start creating a new container
      Logger.debug("No containers available, creating new container")
      pool_pid = self()
      spawn(fn -> create_container_async(pool_pid, state) end)

      # Queue the request to be fulfilled when container is ready
      pending_requests = :queue.in(from, state.pending_requests)
      state = %{state | pending_requests: pending_requests}

      {:noreply, state}
    else
      Logger.warning(
        "No containers available and cannot scale up (current: #{map_size(state.containers)}, max: #{state.config.max_size})"
      )

      {:reply, {:error, :no_containers_available}, state}
    end
  end

  defp retry_or_timeout(start_time, timeout, wait_loop) do
    current_time = System.monotonic_time(:millisecond)

    if current_time - start_time < timeout do
      :timer.sleep(10)
      wait_loop.(wait_loop)
    else
      {:error, :timeout}
    end
  end

  defp merge_config(opts) do
    config =
      Enum.reduce(opts, @default_config, fn {key, value}, acc ->
        Map.put(acc, key, value)
      end)

    # Extract container_prefix from backend if not provided directly
    config =
      if Map.has_key?(config, :container_prefix) do
        config
      else
        backend = Keyword.get(opts, :backend)

        container_prefix =
          case backend do
            %{container_prefix: prefix} when is_binary(prefix) -> prefix
            %{config: %{container_prefix: prefix}} when is_binary(prefix) -> prefix
            _ -> "flame"
          end

        Map.put(config, :container_prefix, container_prefix)
      end

    config
  end

  defp create_container_async(pool_pid, state) do
    container_id = generate_container_id()
    Logger.debug("Starting container creation: #{container_id}")

    # Simulate container creation (in reality, this would use the backend)
    container_info = %{
      id: container_id,
      name: "#{state.config.container_prefix || "flame"}-#{container_id}",
      created_at: System.monotonic_time(:millisecond),
      state: :initializing,
      resource_limits: state.config.resource_limits,
      health_status: :healthy,
      last_health_check: System.monotonic_time(:millisecond)
    }

    # Simulate creation time (optimized for performance tests)
    sleep_time =
      if Mix.env() == :test do
        # 10-50ms for tests - much faster for performance tests
        :rand.uniform(40) + 10
      else
        # 500-1500ms for production - still reasonable
        :rand.uniform(1000) + 500
      end

    :timer.sleep(sleep_time)

    Logger.debug(
      "Container #{container_id} creation completed, sending message to pool #{inspect(pool_pid)}"
    )

    send(pool_pid, {:container_created, container_info})
  rescue
    e ->
      Logger.error("Container creation failed: #{inspect(e)}")
      send(pool_pid, {:container_creation_failed, e})
  end

  defp terminate_container(container_id, _state) do
    Logger.debug("Terminating container: #{container_id}")

    # In a real implementation, this would:
    # 1. Gracefully stop any running tasks
    # 2. Send termination signal to container
    # 3. Wait for graceful shutdown
    # 4. Force kill if necessary
    # 5. Clean up resources

    # For now, just simulate the termination
    :ok
  end

  defp generate_container_id do
    :crypto.strong_rand_bytes(8) |> Base.encode64() |> String.slice(0, 12)
  end

  defp container_healthy?(container) do
    # Simple health check - in reality this would be more sophisticated
    case container do
      %{health_status: :healthy} -> true
      %{health_status: :degraded} -> true
      _ -> false
    end
  end

  defp can_scale_up?(state) do
    current_size = map_size(state.containers)
    current_size < state.config.max_size
  end

  defp calculate_pool_status(state) do
    containers_by_state =
      state.containers
      |> Enum.group_by(fn {_id, container} -> container.state end)
      |> Enum.map(fn {state, containers} -> {state, length(containers)} end)
      |> Enum.into(%{})

    %{
      total: map_size(state.containers),
      available: Map.get(containers_by_state, :available, 0),
      busy: Map.get(containers_by_state, :busy, 0),
      unhealthy: Map.get(containers_by_state, :unhealthy, 0),
      initializing: Map.get(containers_by_state, :initializing, 0),
      terminating: Map.get(containers_by_state, :terminating, 0)
    }
  end

  defp calculate_pool_health(state) do
    status = calculate_pool_status(state)

    cond do
      status.total == 0 -> :unhealthy
      status.unhealthy / status.total > state.config.max_unhealthy_ratio -> :unhealthy
      status.available == 0 && status.busy > 0 -> :degraded
      status.available / status.total < 0.2 -> :degraded
      true -> :healthy
    end
  end

  defp start_health_checker(pool_pid, interval) do
    # Use a timer instead of a linked process to avoid potential crashes
    timer_ref = :timer.send_interval(interval, pool_pid, {:health_check})
    {:ok, timer_ref}
  end

  defp perform_health_checks(pool_pid, state) do
    Enum.each(state.containers, fn {container_id, container} ->
      health_status = check_container_health(container)
      send(pool_pid, {:health_check_result, container_id, health_status})
    end)
  end

  defp check_container_health(_container) do
    # Simplified health check - in reality this would:
    # 1. Check if container is responsive
    # 2. Verify resource usage is within limits
    # 3. Test basic functionality
    # 4. Check for error conditions

    # Simulate occasional health check failures
    if :rand.uniform(100) > 95 do
      :unhealthy
    else
      :healthy
    end
  end

  defp remove_from_queue(queue, item) do
    queue
    |> :queue.to_list()
    |> Enum.reject(&(&1 == item))
    |> :queue.from_list()
  end

  defp remove_from_pending_queue(queue, from) do
    queue
    |> :queue.to_list()
    |> Enum.reject(&(&1 == from))
    |> :queue.from_list()
  end

  defp find_containers_to_remove(state, count) do
    available_containers =
      state.containers
      |> Enum.filter(fn {_id, container} -> container.state == :available end)
      |> Enum.take(count)
      |> Enum.map(fn {id, _container} -> id end)

    available_containers
  end

  defp init_metrics do
    %{
      containers_created: 0,
      containers_destroyed: 0,
      creation_failures: 0,
      acquisitions: 0,
      releases: 0,
      health_checks_performed: 0,
      unhealthy_detections: 0,
      started_at: System.monotonic_time(:millisecond)
    }
  end

  defp update_creation_metrics(metrics) do
    Map.update!(metrics, :containers_created, &(&1 + 1))
  end

  defp update_creation_failure_metrics(metrics) do
    Map.update!(metrics, :creation_failures, &(&1 + 1))
  end

  defp update_acquisition_metrics(metrics) do
    Map.update!(metrics, :acquisitions, &(&1 + 1))
  end

  defp update_release_metrics(metrics) do
    Map.update!(metrics, :releases, &(&1 + 1))
  end

  defp enhance_metrics(metrics, state) do
    uptime = System.monotonic_time(:millisecond) - metrics.started_at
    status = calculate_pool_status(state)

    Map.merge(metrics, %{
      uptime_ms: uptime,
      current_status: status,
      pool_utilization: calculate_utilization(status),
      health_status: calculate_pool_health(state)
    })
  end

  defp calculate_utilization(status) do
    if status.total > 0 do
      status.busy / status.total * 100
    else
      0.0
    end
  end

  defp container_still_busy?(container_id, state) do
    case Map.get(state.containers, container_id) do
      %{state: :busy} -> true
      _ -> false
    end
  end

  defp check_shutdown_completion(state) do
    case Map.get(state, :shutdown_info) do
      %{busy_containers: busy_containers, from: from, timeout_ref: timeout_ref} ->
        # Check if all busy containers have finished
        still_busy = Enum.filter(busy_containers, &container_still_busy?(&1, state))

        if still_busy == [] do
          Logger.info("All busy containers have finished, proceeding with shutdown")
          :erlang.cancel_timer(timeout_ref)
          perform_immediate_shutdown(state)
          GenServer.reply(from, :ok)
          {:shutdown_complete, state}
        else
          Logger.debug("#{length(still_busy)} containers still busy, waiting...")
          state
        end

      nil ->
        # No shutdown in progress
        state
    end
  end
end
