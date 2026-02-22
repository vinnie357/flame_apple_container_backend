defmodule FLAME.Security.RBACTest do
  use ExUnit.Case, async: true

  alias FLAME.Security.RBAC

  setup do
    name = :"rbac_#{System.unique_integer([:positive])}"
    {:ok, pid} = RBAC.start_link(name: name)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{server: pid, name: name}
  end

  describe "start_link/1" do
    test "starts with a custom name", ctx do
      assert Process.alive?(ctx.server)
    end

    test "starts with default options" do
      name = :"rbac_default_#{System.unique_integer([:positive])}"
      {:ok, pid} = RBAC.start_link(name: name)

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      assert Process.alive?(pid)
    end
  end

  describe "authenticate_user/4" do
    test "returns error when no auth adapter configured", ctx do
      # Pass a map for opts so Map.take works (source expects a map, not keyword list)
      result = RBAC.authenticate_user("user", "pass", %{}, ctx.server)
      assert {:error, :auth_adapter_not_configured} = result
    end
  end

  describe "create_session/3" do
    test "returns error for unknown user", ctx do
      result = RBAC.create_session("nonexistent", %{}, ctx.server)
      assert {:error, :user_not_found} = result
    end
  end

  describe "authorize/5" do
    test "returns error for invalid session", ctx do
      result = RBAC.authorize("bad_session", "cluster", "read", %{}, ctx.server)
      assert {:error, :session_not_found} = result
    end
  end

  describe "assign_role/4" do
    test "returns error for unknown user", ctx do
      result = RBAC.assign_role("nonexistent", "admin", %{}, ctx.server)
      assert {:error, :user_not_found} = result
    end
  end

  describe "revoke_role/4" do
    test "returns error for unknown user", ctx do
      result = RBAC.revoke_role("nonexistent", "admin", %{}, ctx.server)
      assert {:error, :user_not_found} = result
    end
  end

  describe "get_user_permissions/2" do
    test "returns error for unknown user", ctx do
      result = RBAC.get_user_permissions("nonexistent", ctx.server)
      assert {:error, :user_not_found} = result
    end
  end

  describe "create_policy/3" do
    test "creates a policy successfully", ctx do
      result = RBAC.create_policy("test_policy", %{type: "custom"}, ctx.server)
      assert :ok = result
    end
  end

  describe "list_sessions/2" do
    test "returns empty list initially", ctx do
      {:ok, sessions} = RBAC.list_sessions(%{}, ctx.server)
      assert sessions == []
    end
  end

  describe "revoke_session/3" do
    test "returns error for nonexistent session", ctx do
      result = RBAC.revoke_session("bad_session", "manual", ctx.server)
      assert {:error, :session_not_found} = result
    end
  end
end
