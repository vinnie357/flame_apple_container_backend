defmodule FLAME.Security.ComplianceManagerTest do
  use ExUnit.Case, async: true

  alias FLAME.Security.ComplianceManager

  setup do
    name = :"compliance_manager_#{System.unique_integer([:positive])}"
    {:ok, pid} = ComplianceManager.start_link(name: name)

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

    test "starts with custom frameworks" do
      name = :"compliance_custom_#{System.unique_integer([:positive])}"
      {:ok, pid} = ComplianceManager.start_link(name: name, frameworks: ["ISO27001"])

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

  describe "get_compliance_status/2" do
    test "returns status for all frameworks", ctx do
      {:ok, status} = ComplianceManager.get_compliance_status(nil, ctx.server)
      assert is_map(status)
      assert Map.has_key?(status, "SOC2_TYPE2")
    end

    test "returns status for a specific framework", ctx do
      {:ok, status} = ComplianceManager.get_compliance_status("SOC2_TYPE2", ctx.server)
      assert is_map(status)
      assert Map.has_key?(status, :score)
    end
  end

  describe "run_compliance_assessment/2" do
    test "runs assessment for all frameworks", ctx do
      {:ok, results} = ComplianceManager.run_compliance_assessment(nil, ctx.server)
      assert is_map(results)
    end

    test "runs assessment for a specific framework", ctx do
      {:ok, result} = ComplianceManager.run_compliance_assessment("SOC2_TYPE2", ctx.server)
      assert is_map(result)
      assert Map.has_key?(result, :score)
    end

    test "returns error for inactive framework", ctx do
      result = ComplianceManager.run_compliance_assessment("NONEXISTENT", ctx.server)
      assert {:error, :framework_not_active} = result
    end
  end

  describe "get_remediation_tasks/2" do
    test "returns empty list initially", ctx do
      {:ok, tasks} = ComplianceManager.get_remediation_tasks(nil, ctx.server)
      assert tasks == []
    end
  end

  describe "configure_framework/3" do
    test "configures a framework", ctx do
      assert :ok = ComplianceManager.configure_framework("SOC2_TYPE2", %{}, ctx.server)
    end
  end

  describe "schedule_assessment/3" do
    test "schedules an assessment", ctx do
      assert :ok =
               ComplianceManager.schedule_assessment(
                 "SOC2_TYPE2",
                 %{frequency: 12},
                 ctx.server
               )
    end
  end
end
