defmodule FLAME.Security.PolicyEngineTest do
  use ExUnit.Case, async: true

  alias FLAME.Security.PolicyEngine

  setup do
    name = :"policy_engine_#{System.unique_integer([:positive])}"
    {:ok, pid} = PolicyEngine.start_link(name: name)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{server: pid, name: name}
  end

  defp valid_policy_spec(overrides \\ %{}) do
    Map.merge(
      %{
        name: "Test Policy",
        type: :access_control,
        description: "A test policy",
        conditions: [%{type: "user_role", operator: "in", values: ["admin"]}],
        actions: [%{type: "audit_log", level: "info", message: "Test"}],
        priority: 100,
        enabled: true
      },
      overrides
    )
  end

  describe "start_link/1" do
    test "starts with a custom name", ctx do
      assert Process.alive?(ctx.server)
    end
  end

  describe "create_policy/2" do
    test "creates a valid policy", ctx do
      assert {:ok, policy_id} = PolicyEngine.create_policy(valid_policy_spec(), ctx.server)
      assert is_binary(policy_id)
    end

    test "rejects policy with missing fields", ctx do
      assert {:error, {:missing_fields, _}} = PolicyEngine.create_policy(%{}, ctx.server)
    end

    test "rejects policy with invalid type", ctx do
      spec = valid_policy_spec(%{name: "Bad Type", type: :nonexistent_type})

      assert {:error, {:invalid_type, :nonexistent_type}} =
               PolicyEngine.create_policy(spec, ctx.server)
    end
  end

  describe "get_policy/2" do
    test "returns error for nonexistent policy", ctx do
      assert {:error, :policy_not_found} = PolicyEngine.get_policy("nonexistent", ctx.server)
    end

    test "retrieves an existing policy", ctx do
      spec = valid_policy_spec(%{name: "Retrieve Test", type: :security, priority: 50})
      {:ok, policy_id} = PolicyEngine.create_policy(spec, ctx.server)
      assert {:ok, policy} = PolicyEngine.get_policy(policy_id, ctx.server)
      assert policy.name == "Retrieve Test"
    end
  end

  describe "update_policy/3" do
    test "updates an existing policy", ctx do
      spec = valid_policy_spec(%{name: "Original", type: :security})
      {:ok, policy_id} = PolicyEngine.create_policy(spec, ctx.server)
      assert :ok = PolicyEngine.update_policy(policy_id, %{name: "Updated"}, ctx.server)

      {:ok, policy} = PolicyEngine.get_policy(policy_id, ctx.server)
      assert policy.name == "Updated"
      assert policy.version == 2
    end

    test "returns error for nonexistent policy", ctx do
      assert {:error, :policy_not_found} =
               PolicyEngine.update_policy("nonexistent", %{}, ctx.server)
    end
  end

  describe "delete_policy/2" do
    test "deletes an existing policy", ctx do
      spec = valid_policy_spec(%{name: "Delete Me", type: :security})
      {:ok, policy_id} = PolicyEngine.create_policy(spec, ctx.server)
      assert :ok = PolicyEngine.delete_policy(policy_id, ctx.server)
      assert {:error, :policy_not_found} = PolicyEngine.get_policy(policy_id, ctx.server)
    end

    test "returns error for nonexistent policy", ctx do
      assert {:error, :policy_not_found} = PolicyEngine.delete_policy("nonexistent", ctx.server)
    end
  end

  describe "list_policies/2" do
    test "lists default policies", ctx do
      {:ok, policies} = PolicyEngine.list_policies(%{}, ctx.server)
      # Default policies are loaded on init
      assert is_list(policies)
      assert length(policies) >= 3
    end
  end

  describe "evaluate_policy/3" do
    test "returns error for nonexistent policy", ctx do
      assert {:error, :policy_not_found} =
               PolicyEngine.evaluate_policy("nonexistent", %{}, ctx.server)
    end
  end

  describe "get_policy_metrics/2" do
    test "returns metrics", ctx do
      assert {:ok, metrics} = PolicyEngine.get_policy_metrics(:hour, ctx.server)
      assert is_map(metrics)
      assert Map.has_key?(metrics, :total_policies)
    end
  end

  describe "enforce_policies/3" do
    test "enforces policies for an enforcement point", ctx do
      assert {:ok, result} =
               PolicyEngine.enforce_policies(:authorization, %{}, ctx.server)

      assert is_map(result)
      assert Map.has_key?(result, :overall_decision)
    end
  end

  describe "test_policy/3" do
    test "tests a policy against contexts", ctx do
      contexts = [
        %{user: %{id: "u1", roles: ["admin"]}},
        %{user: %{id: "u2", roles: ["viewer"]}}
      ]

      assert {:ok, results} = PolicyEngine.test_policy(valid_policy_spec(), contexts, ctx.server)
      assert length(results) == 2
    end
  end
end
