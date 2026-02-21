defmodule FLAME.CircuitBreaker do
  @moduledoc """
  Circuit breaker implementation for container provisioning and task execution.

  Provides exponential backoff, failure tracking, and automatic recovery
  for enhanced reliability in the Apple Containers FLAME backend.
  """

  use GenServer
  require Logger

  defstruct [
    :name,
    :state,
    :failure_count,
    :failure_threshold,
    :timeout,
    :half_open_max_calls,
    :half_open_calls,
    :last_failure_time,
    :backoff_config,
    :current_backoff
  ]

  @default_config %{
    failure_threshold: 5,
    # 1 minute
    timeout: 60_000,
    half_open_max_calls: 3,
    # 1 second
    backoff_initial: 1_000,
    # 5 minutes
    backoff_max: 300_000,
    backoff_multiplier: 2.0,
    backoff_jitter: 0.1
  }

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init(opts) do
    config = Keyword.get(opts, :config, %{}) |> merge_default_config()
    name = Keyword.get(opts, :name, __MODULE__)

    state = %__MODULE__{
      name: name,
      state: :closed,
      failure_count: 0,
      failure_threshold: config.failure_threshold,
      timeout: config.timeout,
      half_open_max_calls: config.half_open_max_calls,
      half_open_calls: 0,
      last_failure_time: nil,
      backoff_config:
        Map.take(config, [:backoff_initial, :backoff_max, :backoff_multiplier, :backoff_jitter]),
      current_backoff: config.backoff_initial
    }

    Logger.info("Circuit breaker #{name} initialized")
    {:ok, state}
  end

  def call(circuit_breaker \\ __MODULE__, operation, timeout \\ 30_000) do
    GenServer.call(circuit_breaker, {:call, operation}, timeout)
  end

  def get_state(circuit_breaker \\ __MODULE__) do
    GenServer.call(circuit_breaker, :get_state)
  end

  def reset(circuit_breaker \\ __MODULE__) do
    GenServer.cast(circuit_breaker, :reset)
  end

  # GenServer callbacks

  def handle_call({:call, operation}, _from, %{state: :open} = state) do
    if should_attempt_reset?(state) do
      # Transition to half-open
      state = %{state | state: :half_open, half_open_calls: 0}
      execute_operation(operation, state)
    else
      {:reply, {:error, :circuit_open}, state}
    end
  end

  def handle_call({:call, operation}, _from, %{state: :half_open} = state) do
    if state.half_open_calls < state.half_open_max_calls do
      execute_operation(operation, state)
    else
      {:reply, {:error, :circuit_half_open_exhausted}, state}
    end
  end

  def handle_call({:call, operation}, _from, %{state: :closed} = state) do
    execute_operation(operation, state)
  end

  def handle_call(:get_state, _from, state) do
    circuit_state = %{
      state: state.state,
      failure_count: state.failure_count,
      failure_threshold: state.failure_threshold,
      current_backoff: state.current_backoff,
      last_failure_time: state.last_failure_time
    }

    {:reply, circuit_state, state}
  end

  def handle_cast(:reset, state) do
    state = %{
      state
      | state: :closed,
        failure_count: 0,
        half_open_calls: 0,
        last_failure_time: nil,
        current_backoff: state.backoff_config.backoff_initial
    }

    Logger.info("Circuit breaker #{state.name} reset")
    {:noreply, state}
  end

  def handle_info(:attempt_reset, state) do
    if state.state == :open do
      Logger.info("Circuit breaker #{state.name} attempting reset from open to half-open")
      state = %{state | state: :half_open, half_open_calls: 0}
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  # Private functions

  defp merge_default_config(config) do
    Map.merge(@default_config, config)
  end

  defp execute_operation(operation, state) do
    start_time = System.monotonic_time(:millisecond)

    try do
      result = operation.()
      execution_time = System.monotonic_time(:millisecond) - start_time

      # Operation succeeded
      state = handle_success(state)
      Logger.debug("Circuit breaker #{state.name} operation succeeded in #{execution_time}ms")

      {:reply, {:ok, result}, state}
    rescue
      error ->
        execution_time = System.monotonic_time(:millisecond) - start_time
        state = handle_failure(state, error)

        Logger.warning(
          "Circuit breaker #{state.name} operation failed in #{execution_time}ms: #{inspect(error)}"
        )

        {:reply, {:error, error}, state}
    catch
      :exit, reason ->
        execution_time = System.monotonic_time(:millisecond) - start_time
        state = handle_failure(state, {:exit, reason})

        Logger.warning(
          "Circuit breaker #{state.name} operation exited in #{execution_time}ms: #{inspect(reason)}"
        )

        {:reply, {:error, {:exit, reason}}, state}

      :throw, value ->
        execution_time = System.monotonic_time(:millisecond) - start_time
        state = handle_failure(state, {:throw, value})

        Logger.warning(
          "Circuit breaker #{state.name} operation threw in #{execution_time}ms: #{inspect(value)}"
        )

        {:reply, {:error, {:throw, value}}, state}
    end
  end

  defp handle_success(%{state: :half_open} = state) do
    # Successful call in half-open state, transition to closed
    %{
      state
      | state: :closed,
        failure_count: 0,
        half_open_calls: 0,
        last_failure_time: nil,
        current_backoff: state.backoff_config.backoff_initial
    }
  end

  defp handle_success(%{state: :closed} = state) do
    # Reset failure count on success in closed state
    %{state | failure_count: 0}
  end

  defp handle_success(state), do: state

  defp handle_failure(state, _error) do
    failure_count = state.failure_count + 1
    current_time = System.system_time(:millisecond)

    state = %{state | failure_count: failure_count, last_failure_time: current_time}

    cond do
      state.state == :half_open ->
        # Failure in half-open state, go back to open
        new_backoff = calculate_backoff(state.current_backoff, state.backoff_config)
        state = %{state | state: :open, current_backoff: new_backoff}
        schedule_reset_attempt(state)

        Logger.warning(
          "Circuit breaker #{state.name} failed in half-open, returning to open state"
        )

        state

      failure_count >= state.failure_threshold ->
        # Threshold reached, open the circuit
        new_backoff = calculate_backoff(state.current_backoff, state.backoff_config)
        state = %{state | state: :open, current_backoff: new_backoff}
        schedule_reset_attempt(state)
        Logger.error("Circuit breaker #{state.name} opened due to #{failure_count} failures")
        state

      true ->
        # Still in closed state, but increment failure count
        Logger.warning(
          "Circuit breaker #{state.name} failure #{failure_count}/#{state.failure_threshold}"
        )

        state
    end
  end

  defp should_attempt_reset?(state) do
    case state.last_failure_time do
      nil ->
        true

      last_failure ->
        System.system_time(:millisecond) - last_failure >= state.current_backoff
    end
  end

  defp schedule_reset_attempt(state) do
    Process.send_after(self(), :attempt_reset, state.current_backoff)
  end

  defp calculate_backoff(current_backoff, config) do
    base_backoff =
      min(
        current_backoff * config.backoff_multiplier,
        config.backoff_max
      )

    # Add jitter to prevent thundering herd
    jitter_amount = base_backoff * config.backoff_jitter
    jitter = :rand.uniform() * jitter_amount * 2 - jitter_amount

    max(config.backoff_initial, trunc(base_backoff + jitter))
  end
end

defmodule FLAME.CircuitBreakerSupervisor do
  @moduledoc """
  Supervisor for circuit breaker instances.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      Supervisor.child_spec({FLAME.CircuitBreaker, [name: :container_provisioning]},
        id: :circuit_breaker_provisioning
      ),
      Supervisor.child_spec({FLAME.CircuitBreaker, [name: :task_execution]},
        id: :circuit_breaker_task_execution
      ),
      Supervisor.child_spec({FLAME.CircuitBreaker, [name: :container_health]},
        id: :circuit_breaker_health
      )
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def get_breaker(name) do
    case Process.whereis(name) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end
end
