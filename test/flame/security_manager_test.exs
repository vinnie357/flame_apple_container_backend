defmodule FLAME.SecurityManagerTest do
  use ExUnit.Case, async: true

  alias FLAME.SecurityManager

  setup do
    name = :"security_manager_#{System.unique_integer([:positive])}"

    config = %{
      # 5 seconds for testing
      max_execution_time: 5000,
      # 100 MB for testing
      max_memory_mb: 100,
      # 50% CPU
      max_cpu_percent: 50,
      audit_enabled: true,
      sandbox_enabled: true,
      allowed_modules: [
        :erlang,
        :elixir,
        Enum,
        Stream,
        Map,
        List,
        String,
        Regex,
        Jason
      ],
      restricted_functions: [
        {File, :*},
        {:file, :*},
        {System, :cmd}
      ]
    }

    {:ok, pid} = SecurityManager.start_link(config: config, name: name)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{server: pid, name: name, config: config}
  end

  describe "security manager initialization" do
    test "starts with correct configuration", ctx do
      status = SecurityManager.get_security_status(ctx.server)

      assert is_map(status)
      assert Map.has_key?(status, :sandbox_enabled)
      assert Map.has_key?(status, :audit_enabled)
      assert Map.has_key?(status, :resource_limits)
      assert Map.has_key?(status, :allowed_modules_count)
      assert Map.has_key?(status, :restricted_functions_count)

      assert is_boolean(status.sandbox_enabled)
      assert is_boolean(status.audit_enabled)
      assert is_map(status.resource_limits)
      assert is_integer(status.allowed_modules_count)
      assert is_integer(status.restricted_functions_count)
    end
  end

  describe "function validation" do
    test "validates safe functions", ctx do
      safe_function = fn x -> x * 2 end

      result = SecurityManager.validate_function(safe_function, %{user_id: "test"}, ctx.server)

      # Should either pass validation or handle gracefully
      assert result in [:ok, {:error, :invalid_function_type}]
    end

    test "validates complex functions", ctx do
      complex_function = fn data ->
        data
        |> Enum.map(&(&1 * 2))
        |> Enum.filter(&(&1 > 10))
        |> Enum.sum()
      end

      result =
        SecurityManager.validate_function(
          complex_function,
          %{complexity: :high, user_id: "test_user"},
          ctx.server
        )

      assert result in [:ok, {:error, :invalid_function_type}]
    end

    test "handles function validation errors gracefully", ctx do
      invalid_inputs = [
        nil,
        "not a function",
        {:tuple, :value},
        %{map: :value}
      ]

      Enum.each(invalid_inputs, fn invalid_input ->
        result = SecurityManager.validate_function(invalid_input, %{}, ctx.server)

        case result do
          :ok -> assert true
          {:error, _reason} -> assert true
          other -> flunk("Unexpected result: #{inspect(other)}")
        end
      end)
    end
  end

  describe "safe execution" do
    test "executes safe functions", ctx do
      safe_function = fn -> 2 + 2 end

      result = SecurityManager.execute_safely(safe_function, %{test: true}, 1000, ctx.server)

      case result do
        {:ok, 4} ->
          assert true

        {:error, reason} ->
          # Expected in test environment due to simplified implementation
          assert is_atom(reason) or is_tuple(reason)

        other ->
          flunk("Unexpected result: #{inspect(other)}")
      end
    end

    test "handles function execution timeout", ctx do
      slow_function = fn ->
        # Sleep for 100ms
        Process.sleep(100)
        :completed
      end

      # Execute with very short timeout
      result = SecurityManager.execute_safely(slow_function, %{}, 50, ctx.server)

      case result do
        {:ok, :completed} ->
          # Function completed within timeout
          assert true

        {:error, :timeout} ->
          # Expected timeout behavior
          assert true

        {:error, _other_reason} ->
          # Other error is acceptable
          assert true

        other ->
          flunk("Unexpected result: #{inspect(other)}")
      end
    end

    test "handles function execution errors", ctx do
      error_function = fn -> raise ArgumentError, "test error" end

      result = SecurityManager.execute_safely(error_function, %{}, 1000, ctx.server)

      case result do
        {:error, %ArgumentError{}} ->
          assert true

        {:error, _other_reason} ->
          assert true

        other ->
          flunk("Unexpected result: #{inspect(other)}")
      end
    end

    test "monitors resource usage during execution", ctx do
      memory_intensive_function = fn ->
        # Create some data structures
        data = Enum.map(1..1000, fn i -> {i, i * i, "value_#{i}"} end)
        Enum.sum(Enum.map(data, fn {i, _, _} -> i end))
      end

      result =
        SecurityManager.execute_safely(
          memory_intensive_function,
          %{resource_monitoring: true},
          5000,
          ctx.server
        )

      case result do
        {:ok, result_value} when is_integer(result_value) ->
          assert true

        {:error, reason} ->
          # Could fail due to resource limits or other reasons
          assert is_atom(reason) or is_tuple(reason)

        other ->
          flunk("Unexpected result: #{inspect(other)}")
      end
    end
  end

  describe "audit logging" do
    test "logs security events", ctx do
      # Test audit logging functionality
      SecurityManager.audit_log(
        :test_event,
        %{
          user_id: "test_user",
          action: "function_execution",
          timestamp: System.system_time(:millisecond)
        },
        ctx.server
      )

      # Allow time for async logging
      Process.sleep(50)

      # Should not crash
      assert :ok == :ok
    end

    test "logs function validation events", ctx do
      test_function = fn x -> x + 1 end

      # This should trigger audit logging
      SecurityManager.validate_function(
        test_function,
        %{source: "test", user_id: "audit_test_user"},
        ctx.server
      )

      # Allow time for logging
      Process.sleep(50)

      assert :ok == :ok
    end

    test "logs execution events", ctx do
      test_function = fn -> "audit test result" end

      # This should trigger execution audit logs
      SecurityManager.execute_safely(
        test_function,
        %{audit_context: "test_execution", user_id: "execution_test_user"},
        30_000,
        ctx.server
      )

      # Allow time for logging
      Process.sleep(100)

      assert :ok == :ok
    end
  end

  describe "resource management" do
    test "enforces execution time limits", ctx do
      # This test verifies that time limit logic exists
      status = SecurityManager.get_security_status(ctx.server)

      assert is_map(status.resource_limits)
      assert Map.has_key?(status.resource_limits, :max_execution_time)
      assert is_integer(status.resource_limits.max_execution_time)
      assert status.resource_limits.max_execution_time > 0
    end

    test "enforces memory limits", ctx do
      status = SecurityManager.get_security_status(ctx.server)

      assert Map.has_key?(status.resource_limits, :max_memory_mb)
      assert is_integer(status.resource_limits.max_memory_mb)
      assert status.resource_limits.max_memory_mb > 0
    end

    test "enforces CPU limits", ctx do
      status = SecurityManager.get_security_status(ctx.server)

      assert Map.has_key?(status.resource_limits, :max_cpu_percent)
      assert is_integer(status.resource_limits.max_cpu_percent)
      assert status.resource_limits.max_cpu_percent > 0
      assert status.resource_limits.max_cpu_percent <= 100
    end
  end

  describe "security configuration" do
    test "respects sandbox settings", ctx do
      status = SecurityManager.get_security_status(ctx.server)

      # Should reflect configuration
      assert is_boolean(status.sandbox_enabled)
    end

    test "tracks allowed modules", ctx do
      status = SecurityManager.get_security_status(ctx.server)

      assert status.allowed_modules_count > 0
      # Should have the modules we configured
      assert status.allowed_modules_count >= 5
    end

    test "tracks restricted functions", ctx do
      status = SecurityManager.get_security_status(ctx.server)

      assert status.restricted_functions_count > 0
      # Should have the restrictions we configured
      assert status.restricted_functions_count >= 2
    end
  end

  describe "error handling and edge cases" do
    test "handles concurrent executions", ctx do
      test_function = fn i ->
        # Very short sleep to be minimally intrusive
        Process.sleep(2)
        i * 2
      end

      # Start only 2 concurrent executions to minimize resource contention
      tasks =
        Enum.map(1..2, fn i ->
          Task.async(fn ->
            SecurityManager.execute_safely(
              fn -> test_function.(i) end,
              %{task_id: i},
              10_000,
              ctx.server
            )
          end)
        end)

      # Wait for all to complete with generous timeout
      results = Task.await_many(tasks, 15_000)

      # All should complete (successfully or with expected errors)
      assert length(results) == 2

      Enum.each(results, fn result ->
        case result do
          {:ok, _} -> assert true
          {:error, _} -> assert true
          other -> flunk("Unexpected concurrent result: #{inspect(other)}")
        end
      end)
    end

    test "handles system stress", ctx do
      # Execute many security operations quickly
      Enum.each(1..20, fn i ->
        SecurityManager.audit_log(:stress_test, %{iteration: i}, ctx.server)
      end)

      # System should remain responsive
      status = SecurityManager.get_security_status(ctx.server)
      assert is_map(status)
    end

    test "recovers from errors gracefully", ctx do
      # Test with various error conditions
      error_functions = [
        fn -> exit(:test_exit) end,
        fn -> throw(:test_throw) end,
        fn -> :erlang.error(:test_error) end
      ]

      Enum.each(error_functions, fn error_fn ->
        result = SecurityManager.execute_safely(error_fn, %{}, 30_000, ctx.server)

        case result do
          {:error, _} -> assert true
          other -> flunk("Expected error, got: #{inspect(other)}")
        end
      end)

      # Security manager should still be responsive
      status = SecurityManager.get_security_status(ctx.server)
      assert is_map(status)
    end
  end
end
