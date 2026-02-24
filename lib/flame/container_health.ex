defmodule FLAME.ContainerHealth do
  @moduledoc """
  Health monitoring system for Apple Containers.

  Provides continuous health checking, alerting, and recovery
  mechanisms for container instances in the FLAME backend.
  """

  use GenServer
  require Logger

  alias FLAME.AppleContainers.CLI

  defstruct [
    :health_checks,
    :check_interval,
    :unhealthy_threshold,
    :recovery_threshold,
    :subscribers
  ]

  @default_config %{
    # 30 seconds
    check_interval: 30_000,
    # 3 consecutive failures
    unhealthy_threshold: 3,
    # 2 consecutive successes
    recovery_threshold: 2,
    # 5 seconds
    health_check_timeout: 5_000
  }

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init(opts) do
    clean_opts = if is_list(opts), do: Keyword.delete(opts, :name), else: opts

    config =
      case clean_opts do
        clean_opts when is_list(clean_opts) -> Keyword.get(clean_opts, :config, %{})
        _ -> %{}
      end
      |> merge_default_config()

    state = %__MODULE__{
      health_checks: %{},
      check_interval: config.check_interval,
      unhealthy_threshold: config.unhealthy_threshold,
      recovery_threshold: config.recovery_threshold,
      subscribers: []
    }

    # Schedule first health check
    schedule_health_check(state.check_interval)

    Logger.info("Container health monitor started")
    {:ok, state}
  end

  def register_container(container_name, health_config \\ %{}, server \\ __MODULE__) do
    GenServer.cast(server, {:register_container, container_name, health_config})
  end

  def unregister_container(container_name, server \\ __MODULE__) do
    GenServer.cast(server, {:unregister_container, container_name})
  end

  def check_container(container_name, server \\ __MODULE__) do
    GenServer.call(server, {:check_container, container_name})
  end

  def get_container_status(container_name, server \\ __MODULE__) do
    GenServer.call(server, {:get_container_status, container_name})
  end

  def subscribe_health_events(pid \\ self(), server \\ __MODULE__) do
    GenServer.cast(server, {:subscribe, pid})
  end

  def unsubscribe_health_events(pid \\ self(), server \\ __MODULE__) do
    GenServer.cast(server, {:unsubscribe, pid})
  end

  # GenServer callbacks

  def handle_cast({:register_container, container_name, health_config}, state) do
    health_info = %{
      container_name: container_name,
      status: :unknown,
      consecutive_failures: 0,
      consecutive_successes: 0,
      last_check: nil,
      last_success: nil,
      last_failure: nil,
      config: health_config,
      registered_at: System.system_time(:millisecond)
    }

    health_checks = Map.put(state.health_checks, container_name, health_info)
    state = %{state | health_checks: health_checks}

    Logger.info("Registered container for health monitoring: #{container_name}")
    {:noreply, state}
  end

  def handle_cast({:unregister_container, container_name}, state) do
    health_checks = Map.delete(state.health_checks, container_name)
    state = %{state | health_checks: health_checks}

    Logger.info("Unregistered container from health monitoring: #{container_name}")
    {:noreply, state}
  end

  def handle_cast({:subscribe, pid}, state) do
    subscribers = [pid | state.subscribers] |> Enum.uniq()
    state = %{state | subscribers: subscribers}
    {:noreply, state}
  end

  def handle_cast({:unsubscribe, pid}, state) do
    subscribers = List.delete(state.subscribers, pid)
    state = %{state | subscribers: subscribers}
    {:noreply, state}
  end

  def handle_call({:check_container, container_name}, _from, state) do
    case Map.get(state.health_checks, container_name) do
      nil ->
        {:reply, :not_monitored, state}

      _health_info ->
        case perform_health_check(container_name) do
          :healthy ->
            {:reply, :healthy, state}

          :unhealthy ->
            {:reply, :unhealthy, state}

          :error ->
            {:reply, :error, state}
        end
    end
  end

  def handle_call({:get_container_status, container_name}, _from, state) do
    case Map.get(state.health_checks, container_name) do
      nil -> {:reply, {:error, :not_monitored}, state}
      health_info -> {:reply, {:ok, health_info}, state}
    end
  end

  def handle_info(:perform_health_checks, state) do
    state = perform_all_health_checks(state)
    schedule_health_check(state.check_interval)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Remove dead subscribers
    subscribers = List.delete(state.subscribers, pid)
    state = %{state | subscribers: subscribers}
    {:noreply, state}
  end

  # Private functions

  defp merge_default_config(config) do
    Map.merge(@default_config, config)
  end

  defp schedule_health_check(interval) do
    Process.send_after(self(), :perform_health_checks, interval)
  end

  defp perform_all_health_checks(state) do
    current_time = System.system_time(:millisecond)

    health_checks =
      Enum.reduce(state.health_checks, %{}, fn {container_name, health_info}, acc ->
        new_health_info = check_container_health(container_name, health_info, current_time, state)
        Map.put(acc, container_name, new_health_info)
      end)

    %{state | health_checks: health_checks}
  end

  defp check_container_health(container_name, health_info, current_time, state) do
    case perform_health_check(container_name) do
      :healthy ->
        handle_healthy_result(health_info, current_time, state)

      :unhealthy ->
        handle_unhealthy_result(health_info, current_time, state, container_name)

      :error ->
        handle_error_result(health_info, current_time, state, container_name)
    end
  end

  defp perform_health_check(container_name) do
    checks = [
      fn -> check_container_running(container_name) end,
      fn -> check_erlang_distribution(container_name) end,
      fn -> check_node_connectivity(container_name) end
    ]

    results =
      Enum.map(checks, fn check ->
        try do
          check.()
        rescue
          _ -> :error
        catch
          :exit, _ -> :error
        end
      end)

    case Enum.all?(results, &(&1 == :ok)) do
      true ->
        :healthy

      false ->
        if Enum.any?(results, &(&1 == :error)) do
          :error
        else
          :unhealthy
        end
    end
  end

  defp check_container_running(container_name) do
    case CLI.adapter().list_containers([
           "--filter",
           "name=#{container_name}",
           "--format",
           "{{.State}}"
         ]) do
      {"running\n", 0} -> :ok
      {_, 0} -> :unhealthy
      {_, _} -> :error
    end
  end

  defp check_erlang_distribution(container_name) do
    case CLI.adapter().exec_in_container(container_name, ["epmd", "-names"]) do
      {output, 0} ->
        if String.contains?(output, "name ") do
          :ok
        else
          :unhealthy
        end

      {_, _} ->
        :error
    end
  end

  defp check_node_connectivity(container_name) do
    # This is a simplified check - in a real implementation you'd want to
    # verify the actual node connection
    case CLI.adapter().exec_in_container(container_name, ["ps", "aux"]) do
      {output, 0} ->
        if String.contains?(output, "beam.smp") or String.contains?(output, "erl") do
          :ok
        else
          :unhealthy
        end

      {_, _} ->
        :error
    end
  end

  defp handle_healthy_result(health_info, current_time, state) do
    consecutive_successes = health_info.consecutive_successes + 1

    new_status =
      if health_info.status == :unhealthy and consecutive_successes >= state.recovery_threshold do
        notify_subscribers(state.subscribers, health_info.container_name, :recovered)
        Logger.info("Container #{health_info.container_name} recovered")
        :healthy
      else
        if health_info.status == :unknown, do: :healthy, else: health_info.status
      end

    %{
      health_info
      | status: new_status,
        consecutive_failures: 0,
        consecutive_successes: consecutive_successes,
        last_check: current_time,
        last_success: current_time
    }
  end

  defp handle_unhealthy_result(health_info, current_time, state, container_name) do
    consecutive_failures = health_info.consecutive_failures + 1

    new_status =
      if health_info.status != :unhealthy and consecutive_failures >= state.unhealthy_threshold do
        notify_subscribers(state.subscribers, container_name, :unhealthy)

        Logger.warning(
          "Container #{container_name} marked as unhealthy after #{consecutive_failures} failures"
        )

        :unhealthy
      else
        health_info.status
      end

    %{
      health_info
      | status: new_status,
        consecutive_failures: consecutive_failures,
        consecutive_successes: 0,
        last_check: current_time,
        last_failure: current_time
    }
  end

  defp handle_error_result(health_info, current_time, state, container_name) do
    consecutive_failures = health_info.consecutive_failures + 1

    new_status =
      if consecutive_failures >= state.unhealthy_threshold do
        notify_subscribers(state.subscribers, container_name, :error)

        Logger.error(
          "Container #{container_name} in error state after #{consecutive_failures} failures"
        )

        :error
      else
        health_info.status
      end

    %{
      health_info
      | status: new_status,
        consecutive_failures: consecutive_failures,
        consecutive_successes: 0,
        last_check: current_time,
        last_failure: current_time
    }
  end

  defp notify_subscribers(subscribers, container_name, event) do
    Enum.each(subscribers, fn subscriber ->
      try do
        send(subscriber, {:container_health_changed, container_name, event})
      catch
        _, _ -> :ok
      end
    end)
  end
end
