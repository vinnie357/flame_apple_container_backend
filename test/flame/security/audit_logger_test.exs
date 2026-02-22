defmodule FLAME.Security.AuditLoggerTest do
  use ExUnit.Case, async: true

  alias FLAME.Security.AuditLogger

  setup do
    name = :"audit_logger_#{System.unique_integer([:positive])}"
    # Use :database backend only to avoid file I/O conflicts in async tests
    {:ok, pid} = AuditLogger.start_link(name: name, storage_backends: [:database])

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
  end

  describe "get_audit_stats/2" do
    test "returns stats", ctx do
      {:ok, stats} = AuditLogger.get_audit_stats(:day, ctx.server)
      assert is_map(stats)
      assert Map.has_key?(stats, :current_stats)
      assert stats.timeframe == :day
    end
  end

  describe "configure_retention/3" do
    test "configures retention policy", ctx do
      assert :ok = AuditLogger.configure_retention(:authentication, 365, ctx.server)
    end
  end

  describe "add_alert_rule/2" do
    test "adds an alert rule", ctx do
      rule = %{
        type: :suspicious_activity,
        name: "Test Rule",
        severity: "medium"
      }

      assert :ok = AuditLogger.add_alert_rule(rule, ctx.server)
    end
  end

  describe "search_audit_logs/2" do
    test "returns results (may be empty)", ctx do
      {:ok, results} = AuditLogger.search_audit_logs(%{}, ctx.server)
      assert is_list(results)
    end
  end

  describe "export_audit_logs/3" do
    test "returns error for unsupported format", ctx do
      assert {:error, :unsupported_format} =
               AuditLogger.export_audit_logs(:xml, %{}, ctx.server)
    end
  end
end
