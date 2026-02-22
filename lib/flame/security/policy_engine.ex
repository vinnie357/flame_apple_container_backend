defmodule FLAME.Security.PolicyEngine do
  @moduledoc """
  Security policy engine for FLAME operations.

  Provides dynamic policy evaluation, enforcement, and management
  for access control, resource usage, and compliance requirements.
  """

  use GenServer
  require Logger
  import Bitwise

  alias FLAME.Security.AuditLogger
  alias FLAME.AlertManager

  # Policy types supported
  @policy_types [
    :access_control,
    :resource_quota,
    :time_based,
    :location_based,
    :compliance,
    :security,
    :custom
  ]

  # Policy enforcement points
  @enforcement_points [
    :authentication,
    :authorization,
    :resource_allocation,
    :data_access,
    :api_gateway,
    :container_lifecycle
  ]

  defstruct [
    :policies,
    :policy_sets,
    :enforcement_config,
    :evaluation_cache,
    :metrics,
    :hooks
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    state = %__MODULE__{
      policies: %{},
      policy_sets: %{},
      enforcement_config: setup_enforcement_config(opts),
      evaluation_cache: %{},
      metrics: initialize_metrics(),
      hooks: setup_policy_hooks(opts)
    }

    # Load default policies
    initial_state = load_default_policies(state)

    # Schedule cache cleanup
    schedule_cache_cleanup()

    Logger.info("Policy engine initialized with #{map_size(initial_state.policies)} policies")
    {:ok, initial_state}
  end

  # Public API

  def create_policy(policy_spec) do
    GenServer.call(__MODULE__, {:create_policy, policy_spec})
  end

  def update_policy(policy_id, updates) do
    GenServer.call(__MODULE__, {:update_policy, policy_id, updates})
  end

  def delete_policy(policy_id) do
    GenServer.call(__MODULE__, {:delete_policy, policy_id})
  end

  def evaluate_policy(policy_id, context) do
    GenServer.call(__MODULE__, {:evaluate_policy, policy_id, context})
  end

  def evaluate_policy_set(policy_set_id, context) do
    GenServer.call(__MODULE__, {:evaluate_policy_set, policy_set_id, context})
  end

  def enforce_policies(enforcement_point, context) do
    GenServer.call(__MODULE__, {:enforce_policies, enforcement_point, context})
  end

  def list_policies(filter \\ %{}) do
    GenServer.call(__MODULE__, {:list_policies, filter})
  end

  def get_policy(policy_id) do
    GenServer.call(__MODULE__, {:get_policy, policy_id})
  end

  def create_policy_set(name, policy_ids, logic \\ :all) do
    GenServer.call(__MODULE__, {:create_policy_set, name, policy_ids, logic})
  end

  def test_policy(policy_spec, test_contexts) do
    GenServer.call(__MODULE__, {:test_policy, policy_spec, test_contexts})
  end

  def get_policy_metrics(timeframe \\ :hour) do
    GenServer.call(__MODULE__, {:get_metrics, timeframe})
  end

  # GenServer callbacks

  def handle_call({:create_policy, policy_spec}, _from, state) do
    case validate_policy_spec(policy_spec) do
      :ok ->
        policy_id = generate_policy_id()

        policy = %{
          id: policy_id,
          name: policy_spec.name,
          type: policy_spec.type,
          description: policy_spec.description,
          conditions: policy_spec.conditions,
          actions: policy_spec.actions,
          priority: policy_spec.priority || 100,
          enabled: policy_spec.enabled != false,
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now(),
          version: 1
        }

        updated_policies = Map.put(state.policies, policy_id, policy)
        updated_state = %{state | policies: updated_policies}

        AuditLogger.log_system_event(%{
          event: "policy_created",
          policy_id: policy_id,
          policy_name: policy.name,
          policy_type: policy.type,
          timestamp: DateTime.utc_now()
        })

        {:reply, {:ok, policy_id}, updated_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:update_policy, policy_id, updates}, _from, state) do
    case Map.get(state.policies, policy_id) do
      nil ->
        {:reply, {:error, :policy_not_found}, state}

      policy ->
        updated_policy = %{
          policy
          | name: Map.get(updates, :name, policy.name),
            description: Map.get(updates, :description, policy.description),
            conditions: Map.get(updates, :conditions, policy.conditions),
            actions: Map.get(updates, :actions, policy.actions),
            priority: Map.get(updates, :priority, policy.priority),
            enabled: Map.get(updates, :enabled, policy.enabled),
            updated_at: DateTime.utc_now(),
            version: policy.version + 1
        }

        updated_policies = Map.put(state.policies, policy_id, updated_policy)
        updated_state = %{state | policies: updated_policies}

        # Clear cache for this policy
        cache_key = "policy_#{policy_id}"
        updated_cache = Map.delete(state.evaluation_cache, cache_key)
        final_state = %{updated_state | evaluation_cache: updated_cache}

        AuditLogger.log_system_event(%{
          event: "policy_updated",
          policy_id: policy_id,
          changes: updates,
          timestamp: DateTime.utc_now()
        })

        {:reply, :ok, final_state}
    end
  end

  def handle_call({:delete_policy, policy_id}, _from, state) do
    case Map.get(state.policies, policy_id) do
      nil ->
        {:reply, {:error, :policy_not_found}, state}

      policy ->
        updated_policies = Map.delete(state.policies, policy_id)

        # Remove from policy sets
        updated_policy_sets =
          state.policy_sets
          |> Enum.map(fn {set_id, policy_set} ->
            updated_policies_list = List.delete(policy_set.policies, policy_id)
            {set_id, %{policy_set | policies: updated_policies_list}}
          end)
          |> Map.new()

        # Clear related cache entries
        updated_cache =
          state.evaluation_cache
          |> Enum.reject(fn {key, _} -> String.contains?(key, policy_id) end)
          |> Map.new()

        updated_state = %{
          state
          | policies: updated_policies,
            policy_sets: updated_policy_sets,
            evaluation_cache: updated_cache
        }

        AuditLogger.log_system_event(%{
          event: "policy_deleted",
          policy_id: policy_id,
          policy_name: policy.name,
          timestamp: DateTime.utc_now()
        })

        {:reply, :ok, updated_state}
    end
  end

  def handle_call({:evaluate_policy, policy_id, context}, _from, state) do
    case Map.get(state.policies, policy_id) do
      nil ->
        {:reply, {:error, :policy_not_found}, state}

      policy ->
        if policy.enabled do
          # Check cache first
          cache_key = generate_cache_key(policy_id, context)

          case Map.get(state.evaluation_cache, cache_key) do
            nil ->
              # Record cache miss
              record_cache_metric(:miss)

              # Evaluate policy
              result = evaluate_policy_impl(policy, context)

              # Cache result for 5 minutes
              cache_entry = {result, DateTime.utc_now()}
              updated_cache = Map.put(state.evaluation_cache, cache_key, cache_entry)
              updated_state = %{state | evaluation_cache: updated_cache}

              # Record metrics
              record_policy_evaluation(policy, result, updated_state)

              {:reply, {:ok, result}, updated_state}

            {cached_result, cached_at} ->
              # Check if cache is still valid (5 minutes)
              if DateTime.diff(DateTime.utc_now(), cached_at, :second) < 300 do
                # Record cache hit
                record_cache_metric(:hit)
                {:reply, {:ok, cached_result}, state}
              else
                # Expired entry counts as a miss
                record_cache_metric(:miss)

                # Re-evaluate and update cache
                result = evaluate_policy_impl(policy, context)
                cache_entry = {result, DateTime.utc_now()}
                updated_cache = Map.put(state.evaluation_cache, cache_key, cache_entry)
                updated_state = %{state | evaluation_cache: updated_cache}

                {:reply, {:ok, result}, updated_state}
              end
          end
        else
          {:reply, {:ok, %{decision: :not_applicable, reason: "policy_disabled"}}, state}
        end
    end
  end

  def handle_call({:evaluate_policy_set, policy_set_id, context}, _from, state) do
    case Map.get(state.policy_sets, policy_set_id) do
      nil ->
        {:reply, {:error, :policy_set_not_found}, state}

      policy_set ->
        results = evaluate_policy_set_impl(policy_set, context, state)
        {:reply, {:ok, results}, state}
    end
  end

  def handle_call({:enforce_policies, enforcement_point, context}, _from, state) do
    applicable_policies = get_applicable_policies(enforcement_point, state)
    enforcement_results = enforce_policies_impl(applicable_policies, context, state)

    {:reply, {:ok, enforcement_results}, state}
  end

  def handle_call({:list_policies, filter}, _from, state) do
    filtered_policies = filter_policies(state.policies, filter)
    {:reply, {:ok, filtered_policies}, state}
  end

  def handle_call({:get_policy, policy_id}, _from, state) do
    case Map.get(state.policies, policy_id) do
      nil -> {:reply, {:error, :policy_not_found}, state}
      policy -> {:reply, {:ok, policy}, state}
    end
  end

  def handle_call({:create_policy_set, name, policy_ids, logic}, _from, state) do
    # Validate that all policies exist
    invalid_policies = Enum.reject(policy_ids, &Map.has_key?(state.policies, &1))

    if Enum.empty?(invalid_policies) do
      policy_set_id = generate_policy_set_id()

      policy_set = %{
        id: policy_set_id,
        name: name,
        policies: policy_ids,
        # :all, :any, :majority
        logic: logic,
        created_at: DateTime.utc_now()
      }

      updated_policy_sets = Map.put(state.policy_sets, policy_set_id, policy_set)
      updated_state = %{state | policy_sets: updated_policy_sets}

      {:reply, {:ok, policy_set_id}, updated_state}
    else
      {:reply, {:error, {:invalid_policies, invalid_policies}}, state}
    end
  end

  def handle_call({:test_policy, policy_spec, test_contexts}, _from, state) do
    case validate_policy_spec(policy_spec) do
      :ok ->
        test_policy = %{
          id: "test_policy",
          name: policy_spec.name,
          type: policy_spec.type,
          conditions: policy_spec.conditions,
          actions: policy_spec.actions,
          enabled: true
        }

        test_results =
          test_contexts
          |> Enum.map(fn context ->
            result = evaluate_policy_impl(test_policy, context)
            %{context: context, result: result}
          end)

        {:reply, {:ok, test_results}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_metrics, timeframe}, _from, state) do
    metrics = calculate_policy_metrics(timeframe, state)
    {:reply, {:ok, metrics}, state}
  end

  def handle_info(:cleanup_cache, state) do
    # Remove expired cache entries
    current_time = DateTime.utc_now()

    updated_cache =
      state.evaluation_cache
      |> Enum.reject(fn {_key, {_result, cached_at}} ->
        # 5 minutes
        DateTime.diff(current_time, cached_at, :second) > 300
      end)
      |> Map.new()

    schedule_cache_cleanup()

    {:noreply, %{state | evaluation_cache: updated_cache}}
  end

  # Private implementation

  defp validate_policy_spec(policy_spec) do
    required_fields = [:name, :type, :conditions, :actions]

    missing_fields =
      required_fields
      |> Enum.reject(&Map.has_key?(policy_spec, &1))

    cond do
      not Enum.empty?(missing_fields) ->
        {:error, {:missing_fields, missing_fields}}

      policy_spec.type not in @policy_types ->
        {:error, {:invalid_type, policy_spec.type}}

      not is_list(policy_spec.conditions) ->
        {:error, :invalid_conditions_format}

      not is_list(policy_spec.actions) ->
        {:error, :invalid_actions_format}

      true ->
        :ok
    end
  end

  defp evaluate_policy_impl(policy, context) do
    Logger.debug("Evaluating policy #{policy.id} with context: #{inspect(context)}")

    start_time = System.monotonic_time(:microsecond)

    try do
      # Evaluate all conditions
      conditions_result = evaluate_conditions(policy.conditions, context)

      decision =
        if conditions_result.all_match do
          # Execute actions
          actions_result = execute_actions(policy.actions, context)

          %{
            decision: :permit,
            reason: "policy_conditions_satisfied",
            actions_executed: actions_result.executed,
            metadata: %{
              policy_id: policy.id,
              policy_name: policy.name,
              conditions_matched: conditions_result.matched_conditions
            }
          }
        else
          %{
            decision: :deny,
            reason: "policy_conditions_not_satisfied",
            metadata: %{
              policy_id: policy.id,
              policy_name: policy.name,
              failed_conditions: conditions_result.failed_conditions
            }
          }
        end

      execution_time = System.monotonic_time(:microsecond) - start_time

      AuditLogger.log_security_event(%{
        event: "policy_evaluated",
        policy_id: policy.id,
        decision: decision.decision,
        execution_time_us: execution_time,
        context: context,
        timestamp: DateTime.utc_now()
      })

      decision
    catch
      kind, reason ->
        Logger.error("Policy evaluation failed: #{inspect({kind, reason})}")

        %{
          decision: :indeterminate,
          reason: "policy_evaluation_error",
          error: %{kind: kind, reason: reason}
        }
    end
  end

  defp evaluate_conditions(conditions, context) do
    {matched, failed} =
      conditions
      |> Enum.split_with(&evaluate_single_condition(&1, context))

    %{
      all_match: Enum.empty?(failed),
      matched_conditions: matched,
      failed_conditions: failed
    }
  end

  defp evaluate_single_condition(condition, context) do
    case condition do
      %{type: "user_role", operator: "in", values: roles} ->
        user_roles = get_in(context, [:user, :roles]) || []
        not Enum.empty?(user_roles -- (user_roles -- roles))

      %{type: "resource_owner", operator: "equals"} ->
        user_id = get_in(context, [:user, :id])
        resource_owner = get_in(context, [:resource, :owner_id])
        user_id == resource_owner

      %{type: "time_range", start_hour: start_h, end_hour: end_h} ->
        current_hour = DateTime.utc_now().hour
        current_hour >= start_h and current_hour <= end_h

      %{type: "ip_address", operator: "in_range", cidr: cidr} ->
        client_ip = get_in(context, [:request, :ip])
        ip_in_cidr?(client_ip, cidr)

      %{type: "resource_type", operator: "equals", value: resource_type} ->
        context_resource_type = get_in(context, [:resource, :type])
        context_resource_type == resource_type

      %{type: "custom", function: function_name, args: args} ->
        evaluate_custom_condition(function_name, args, context)

      _ ->
        Logger.warning("Unknown condition type: #{inspect(condition)}")
        false
    end
  end

  defp execute_actions(actions, context) do
    executed_actions =
      actions
      |> Enum.map(&execute_single_action(&1, context))
      |> Enum.filter(& &1.success)

    %{
      executed: executed_actions,
      total: length(actions)
    }
  end

  defp execute_single_action(action, context) do
    try do
      case action do
        %{type: "audit_log", level: level, message: message} ->
          AuditLogger.log_security_event(%{
            event: "policy_action_executed",
            action_type: "audit_log",
            level: level,
            message: message,
            context: context,
            timestamp: DateTime.utc_now()
          })

          %{action: action, success: true}

        %{type: "send_alert", severity: severity, message: message} ->
          AlertManager.create_alert(%{
            type: "policy_alert",
            severity: severity,
            title: "Policy Action Alert",
            description: message,
            metadata: context
          })

          %{action: action, success: true}

        %{type: "block_request"} ->
          # This would typically set a flag in the context
          # that the calling system would check
          %{action: action, success: true, effect: :block}

        %{type: "rate_limit", limit: limit, window: window} ->
          # Implement rate limiting logic
          apply_rate_limit(context, limit, window)
          %{action: action, success: true}

        _ ->
          Logger.warning("Unknown action type: #{inspect(action)}")
          %{action: action, success: false, reason: "unknown_action_type"}
      end
    catch
      kind, reason ->
        Logger.error("Action execution failed: #{inspect({kind, reason})}")
        %{action: action, success: false, error: %{kind: kind, reason: reason}}
    end
  end

  defp evaluate_policy_set_impl(policy_set, context, state) do
    policy_results =
      policy_set.policies
      |> Enum.map(fn policy_id ->
        case Map.get(state.policies, policy_id) do
          nil ->
            {:error, :policy_not_found}

          policy ->
            {:ok, evaluate_policy_impl(policy, context)}
        end
      end)

    # Apply set logic
    final_decision =
      case policy_set.logic do
        :all -> all_permit?(policy_results)
        :any -> any_permit?(policy_results)
        :majority -> majority_permit?(policy_results)
      end

    %{
      policy_set_id: policy_set.id,
      decision: final_decision,
      individual_results: policy_results,
      logic: policy_set.logic
    }
  end

  defp all_permit?(results) do
    Enum.all?(results, fn
      {:ok, %{decision: :permit}} -> true
      _ -> false
    end)
  end

  defp any_permit?(results) do
    Enum.any?(results, fn
      {:ok, %{decision: :permit}} -> true
      _ -> false
    end)
  end

  defp majority_permit?(results) do
    permit_count =
      results
      |> Enum.count(fn
        {:ok, %{decision: :permit}} -> true
        _ -> false
      end)

    permit_count > length(results) / 2
  end

  defp get_applicable_policies(enforcement_point, state) do
    state.policies
    |> Map.values()
    |> Enum.filter(fn policy ->
      policy.enabled and applies_to_enforcement_point?(policy, enforcement_point)
    end)
    |> Enum.sort_by(& &1.priority, :desc)
  end

  defp applies_to_enforcement_point?(policy, enforcement_point) do
    # Check if policy applies to this enforcement point
    policy_enforcement_points = Map.get(policy, :enforcement_points, @enforcement_points)
    enforcement_point in policy_enforcement_points
  end

  defp enforce_policies_impl(policies, context, _state) do
    results =
      policies
      |> Enum.map(fn policy ->
        result = evaluate_policy_impl(policy, context)
        {policy.id, result}
      end)

    # Determine overall enforcement decision
    overall_decision = determine_overall_decision(results)

    %{
      enforcement_point: context[:enforcement_point],
      overall_decision: overall_decision,
      policy_results: results,
      context: context,
      timestamp: DateTime.utc_now()
    }
  end

  defp determine_overall_decision(results) do
    # If any policy explicitly denies, deny
    # If any policy permits and none deny, permit
    # Otherwise, deny by default

    has_permit = Enum.any?(results, fn {_id, result} -> result.decision == :permit end)
    has_deny = Enum.any?(results, fn {_id, result} -> result.decision == :deny end)

    cond do
      has_deny -> :deny
      has_permit -> :permit
      true -> :deny
    end
  end

  defp filter_policies(policies, filter) do
    policies
    |> Map.values()
    |> Enum.filter(fn policy ->
      Enum.all?(filter, fn {key, value} ->
        case key do
          :type -> policy.type == value
          :enabled -> policy.enabled == value
          :name_contains -> String.contains?(policy.name, value)
          _ -> true
        end
      end)
    end)
  end

  defp record_policy_evaluation(policy, result, _state) do
    Logger.debug("Policy #{policy.id} evaluated with decision: #{result.decision}")
  end

  defp record_cache_metric(type) do
    metrics = Process.get(:policy_engine_metrics) || %{cache_hits: 0, cache_misses: 0}

    updated =
      case type do
        :hit -> Map.update(metrics, :cache_hits, 1, &(&1 + 1))
        :miss -> Map.update(metrics, :cache_misses, 1, &(&1 + 1))
      end

    Process.put(:policy_engine_metrics, updated)
  end

  defp calculate_policy_metrics(timeframe, state) do
    # Simplified metrics calculation
    %{
      total_policies: map_size(state.policies),
      enabled_policies: count_enabled_policies(state.policies),
      cache_hit_rate: calculate_cache_hit_rate(state.evaluation_cache),
      timeframe: timeframe,
      calculated_at: DateTime.utc_now()
    }
  end

  defp count_enabled_policies(policies) do
    policies |> Map.values() |> Enum.count(& &1.enabled)
  end

  defp calculate_cache_hit_rate(_cache) do
    hits = Map.get(Process.get(:policy_engine_metrics) || %{}, :cache_hits, 0)
    misses = Map.get(Process.get(:policy_engine_metrics) || %{}, :cache_misses, 0)
    total = hits + misses

    if total > 0 do
      Float.round(hits / total * 100.0, 1)
    else
      0.0
    end
  end

  # Utility functions

  defp generate_cache_key(policy_id, context) do
    context_hash = :crypto.hash(:sha256, :erlang.term_to_binary(context)) |> Base.encode16()
    "policy_#{policy_id}_#{String.slice(context_hash, 0, 8)}"
  end

  defp ip_in_cidr?(ip_string, cidr) when is_binary(ip_string) and is_binary(cidr) do
    with [network_str, prefix_str] <- String.split(cidr, "/", parts: 2),
         {prefix_len, ""} <- Integer.parse(prefix_str),
         {:ok, ip_addr} <- :inet.parse_address(String.to_charlist(ip_string)),
         {:ok, network_addr} <- :inet.parse_address(String.to_charlist(network_str)) do
      ip_in_cidr_match?(ip_addr, network_addr, prefix_len)
    else
      _ ->
        Logger.debug("Failed to parse IP #{inspect(ip_string)} or CIDR #{inspect(cidr)}")
        false
    end
  end

  defp ip_in_cidr?(_ip, _cidr), do: false

  defp ip_in_cidr_match?(ip_tuple, network_tuple, prefix_len)
       when tuple_size(ip_tuple) == 4 and tuple_size(network_tuple) == 4 do
    # IPv4: convert to 32-bit integers and compare masked values
    ip_int = ip_tuple_to_integer(ip_tuple)
    net_int = ip_tuple_to_integer(network_tuple)

    mask =
      if prefix_len == 0, do: 0, else: Bitwise.bnot((1 <<< (32 - prefix_len)) - 1) &&& 0xFFFFFFFF

    (ip_int &&& mask) == (net_int &&& mask)
  end

  defp ip_in_cidr_match?(ip_tuple, network_tuple, prefix_len)
       when tuple_size(ip_tuple) == 8 and tuple_size(network_tuple) == 8 do
    # IPv6: convert to 128-bit integers and compare masked values
    ip_int = ipv6_tuple_to_integer(ip_tuple)
    net_int = ipv6_tuple_to_integer(network_tuple)

    mask =
      if prefix_len == 0,
        do: 0,
        else: Bitwise.bnot((1 <<< (128 - prefix_len)) - 1) &&& (1 <<< 128) - 1

    (ip_int &&& mask) == (net_int &&& mask)
  end

  defp ip_in_cidr_match?(_, _, _), do: false

  defp ip_tuple_to_integer({a, b, c, d}) do
    Bitwise.bsl(a, 24) ||| Bitwise.bsl(b, 16) ||| Bitwise.bsl(c, 8) ||| d
  end

  defp ipv6_tuple_to_integer({a, b, c, d, e, f, g, h}) do
    Bitwise.bsl(a, 112) ||| Bitwise.bsl(b, 96) ||| Bitwise.bsl(c, 80) ||| Bitwise.bsl(d, 64) |||
      Bitwise.bsl(e, 48) ||| Bitwise.bsl(f, 32) ||| Bitwise.bsl(g, 16) ||| h
  end

  defp evaluate_custom_condition(function_name, args, context) do
    custom_conditions =
      Application.get_env(:flame_apple_container_backend, :custom_policy_conditions, %{})

    case Map.get(custom_conditions, function_name) do
      nil ->
        Logger.debug(
          "No custom condition registered for #{function_name}. " <>
            "Register via :custom_policy_conditions in app config."
        )

        false

      fun when is_function(fun, 2) ->
        try do
          fun.(args, context)
        rescue
          e ->
            Logger.error("Custom condition #{function_name} raised: #{inspect(e)}")
            false
        end

      {module, function} when is_atom(module) and is_atom(function) ->
        try do
          apply(module, function, [args, context])
        rescue
          e ->
            Logger.error("Custom condition #{module}.#{function} raised: #{inspect(e)}")
            false
        end

      other ->
        Logger.warning("Invalid custom condition entry for #{function_name}: #{inspect(other)}")
        false
    end
  end

  defp apply_rate_limit(context, limit, window) do
    # Use a configurable rate limiter if available, otherwise use ETS-based counter
    case Application.get_env(:flame_apple_container_backend, :rate_limiter) do
      nil ->
        apply_ets_rate_limit(context, limit, window)

      module when is_atom(module) ->
        module.check_rate(context, limit, window)
    end
  end

  defp apply_ets_rate_limit(context, limit, window) do
    table = ensure_rate_limit_table()
    # Build a key from the context (user_id + resource, or IP, etc.)
    key = rate_limit_key(context)
    now = System.monotonic_time(:second)
    window_start = now - window

    # Clean up expired entries for this key, then count remaining
    existing =
      case :ets.lookup(table, key) do
        [{^key, timestamps}] -> Enum.filter(timestamps, &(&1 > window_start))
        [] -> []
      end

    if length(existing) >= limit do
      Logger.debug(
        "Rate limit exceeded for #{inspect(key)}: #{length(existing)}/#{limit} in #{window}s"
      )

      {:error, :rate_limited}
    else
      :ets.insert(table, {key, [now | existing]})
      :ok
    end
  end

  defp ensure_rate_limit_table do
    table = :flame_policy_rate_limits

    case :ets.whereis(table) do
      :undefined -> :ets.new(table, [:named_table, :public, :set])
      _ref -> table
    end
  end

  defp rate_limit_key(context) do
    user_id = get_in(context, [:user, :id]) || "anonymous"
    resource = get_in(context, [:resource, :type]) || "global"
    {user_id, resource}
  end

  defp load_default_policies(state) do
    default_policies = [
      %{
        name: "Admin Full Access",
        type: :access_control,
        description: "Allow full access for admin users",
        conditions: [
          %{type: "user_role", operator: "in", values: ["admin"]}
        ],
        actions: [
          %{type: "audit_log", level: "info", message: "Admin access granted"}
        ],
        priority: 1000,
        enforcement_points: @enforcement_points
      },
      %{
        name: "Business Hours Access",
        type: :time_based,
        description: "Restrict access to business hours",
        conditions: [
          %{type: "time_range", start_hour: 9, end_hour: 17}
        ],
        actions: [
          %{type: "audit_log", level: "info", message: "Business hours access"}
        ],
        priority: 500
      },
      %{
        name: "Resource Owner Access",
        type: :access_control,
        description: "Allow resource owners full access to their resources",
        conditions: [
          %{type: "resource_owner", operator: "equals"}
        ],
        actions: [
          %{type: "audit_log", level: "info", message: "Resource owner access granted"}
        ],
        priority: 800
      }
    ]

    policies_with_ids =
      default_policies
      |> Enum.map(fn policy_spec ->
        policy_id = generate_policy_id()

        policy = %{
          id: policy_id,
          name: policy_spec.name,
          type: policy_spec.type,
          description: policy_spec.description,
          conditions: policy_spec.conditions,
          actions: policy_spec.actions,
          priority: policy_spec.priority,
          enabled: true,
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now(),
          version: 1,
          enforcement_points: Map.get(policy_spec, :enforcement_points, [:authorization])
        }

        {policy_id, policy}
      end)
      |> Map.new()

    %{state | policies: policies_with_ids}
  end

  defp setup_enforcement_config(opts) do
    %{
      default_decision: Keyword.get(opts, :default_decision, :deny),
      evaluation_timeout: Keyword.get(opts, :evaluation_timeout, 5000),
      cache_enabled: Keyword.get(opts, :cache_enabled, true),
      metrics_enabled: Keyword.get(opts, :metrics_enabled, true)
    }
  end

  defp setup_policy_hooks(opts) do
    %{
      pre_evaluation: Keyword.get(opts, :pre_evaluation_hooks, []),
      post_evaluation: Keyword.get(opts, :post_evaluation_hooks, []),
      policy_changed: Keyword.get(opts, :policy_changed_hooks, [])
    }
  end

  defp initialize_metrics do
    %{
      evaluations_total: 0,
      cache_hits: 0,
      cache_misses: 0,
      errors: 0,
      last_reset: DateTime.utc_now()
    }
  end

  defp schedule_cache_cleanup do
    # 1 minute
    Process.send_after(self(), :cleanup_cache, 60_000)
  end

  defp generate_policy_id do
    "policy_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp generate_policy_set_id do
    "policy_set_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
