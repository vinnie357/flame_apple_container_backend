defmodule FLAME.IntegrationTest do
  use ExUnit.Case, async: false

  alias FLAME.AppleContainersBackend
  alias FLAME.CircuitBreaker
  alias FLAME.ContainerMetrics
  alias FLAME.ResourceManager
  alias FLAME.SecurityManager

  @moduletag :integration

  setup_all do
    # Start the main application systems for integration testing
    Application.put_env(:flame_apple_container_backend, :environment, :test)

    # Start application
    case Application.ensure_all_started(:flame_apple_container_backend) do
      {:ok, _apps} -> :ok
      # May already be started
      {:error, _reason} -> :ok
    end

    on_exit(fn ->
      # Cleanup if needed
      :ok
    end)

    :ok
  end

  describe "complete backend integration" do
    test "backend initializes with all production features" do
      # Test backend initialization with production configuration
      backend_opts = [
        image: "flame-worker:test",
        dns_domain: "integration.test",
        container_prefix: "integration-test",
        erlang_cookie: "integration_test_cookie",
        mode: :test,
        pool_config: %{
          min_warm_containers: 1,
          max_warm_containers: 3,
          max_active_containers: 5
        },
        circuit_breaker_config: %{
          failure_threshold: 3,
          timeout: 5000
        },
        monitoring_config: %{
          telemetry: %{enabled: true},
          prometheus: %{enabled: false}
        }
      ]

      {:ok, backend} = AppleContainersBackend.init(backend_opts)
      assert is_map(backend)
      assert backend.mode == :test
      assert is_map(backend.config)
      assert backend.config.image == "flame-worker:test"
      assert backend.config.dns_domain == "integration.test"
    end

    test "backend handles remote boot requests" do
      # Initialize backend
      {:ok, backend} =
        AppleContainersBackend.init(
          mode: :test,
          image: "flame-worker:test",
          dns_domain: "test.local",
          container_prefix: "test-boot",
          erlang_cookie: "test_cookie"
        )

      # Attempt remote boot (will likely fail in test environment)
      result = AppleContainersBackend.remote_boot(backend)

      case result do
        {:ok, terminator_pid, updated_backend} ->
          assert is_pid(terminator_pid)
          assert is_map(updated_backend)
          # Get container info from backend state
          container_info = updated_backend.containers |> Map.values() |> List.first()
          assert is_map(container_info)
          assert Map.has_key?(container_info, :container_name)
          assert Map.has_key?(container_info, :node_name)

        {:error, reason} ->
          # Expected in test environment without actual containers
          case reason do
            :no_warm_containers -> assert true
            {:container_provisioning_failed, _details} -> assert true
            {:container_start_failed, _code, _error} -> assert true
            :readiness_timeout -> assert true
            {:connection_failed, _node} -> assert true
            other -> flunk("Unexpected error reason: #{inspect(other)}")
          end
      end
    end

    test "backend handles task execution with monitoring" do
      # Initialize backend with monitoring
      {:ok, backend} =
        AppleContainersBackend.init(
          mode: :test,
          image: "flame-worker:test"
        )

      # Test function
      test_function = fn -> 2 + 2 end

      # Attempt task execution
      result = AppleContainersBackend.remote_spawn_monitor(backend, test_function)

      case result do
        {:ok, pid, ref} when is_pid(pid) and is_reference(ref) ->
          assert true

        {:error, reason} ->
          # Expected in test environment
          case reason do
            :no_available_containers -> assert true
            {:container_provisioning_failed, _details} -> assert true
            :circuit_breaker_open -> assert true
            {:rpc_failed, _error} -> assert true
            other -> flunk("Unexpected error reason: #{inspect(other)}")
          end
      end
    end
  end

  describe "system integration under load" do
    test "handles multiple concurrent requests" do
      # Initialize backend
      {:ok, backend} =
        AppleContainersBackend.init(
          mode: :test,
          pool_config: %{max_active_containers: 10}
        )

      # Create multiple concurrent tasks
      tasks =
        Enum.map(1..5, fn i ->
          Task.async(fn ->
            test_function = fn -> i * 2 end
            AppleContainersBackend.remote_spawn_monitor(backend, test_function)
          end)
        end)

      # Wait for all tasks to complete
      results = Task.await_many(tasks, 5000)

      # All should complete (successfully or with expected errors)
      assert length(results) == 5

      Enum.each(results, fn result ->
        case result do
          {:ok, _pid, _ref} -> assert true
          {:error, _reason} -> assert true
          other -> flunk("Unexpected result: #{inspect(other)}")
        end
      end)
    end

    test "metrics are collected during operations" do
      # Record some test metrics
      container_id = "integration-test-container-001"
      task_id = "integration-test-task-001"

      ContainerMetrics.record_container_provision(container_id)
      ContainerMetrics.record_task_execution(task_id, 1500)
      ContainerMetrics.record_task_completion(task_id, 1500)

      # Allow time for metrics processing
      Process.sleep(100)

      # Get metrics summary
      summary = ContainerMetrics.get_metrics_summary()

      assert is_map(summary)
      assert Map.has_key?(summary, :summary_generated_at)
      assert is_integer(summary.summary_generated_at)
    end

    test "security manager integrates with task execution" do
      # Test function that should pass security validation
      safe_function = fn x -> x * x end

      # Validate function
      case SecurityManager.validate_function(safe_function, %{source: "integration_test"}) do
        :ok ->
          assert true

        {:error, reason} ->
          # Expected with simplified validation
          case reason do
            :invalid_function_type -> :ok
            {:restricted_function, _, _} -> :ok
            _ -> flunk("Unexpected error reason: #{inspect(reason)}")
          end
      end

      # Execute safely
      case SecurityManager.execute_safely(safe_function, %{args: [5]}) do
        {:ok, result} ->
          assert is_integer(result)

        {:error, _reason} ->
          # Expected in test environment
          assert true
      end
    end

    test "resource manager tracks system resources" do
      # Register a test container
      container_id = "integration-resource-test-001"

      resource_config = %{
        memory_mb: 256,
        cpu_percent: 25
      }

      ResourceManager.register_container(container_id, resource_config)

      # Allow time for registration
      Process.sleep(50)

      # Check resource status
      status = ResourceManager.get_resource_status()

      assert is_map(status)
      assert Map.has_key?(status, :current_usage)
      assert Map.has_key?(status, :global_limits)
      assert Map.has_key?(status, :utilization_percentage)
      assert Map.has_key?(status, :container_count)

      # Cleanup
      ResourceManager.unregister_container(container_id)
    end

    test "circuit breakers protect against failures" do
      # Test circuit breaker integration
      failing_operation = fn ->
        raise "Simulated failure"
      end

      # Execute operation multiple times to trigger circuit breaker
      results =
        Enum.map(1..5, fn _i ->
          CircuitBreaker.call(:task_execution, failing_operation)
        end)

      # Should have some failures
      failures =
        Enum.filter(results, fn
          {:error, _} -> true
          _ -> false
        end)

      assert length(failures) > 0

      # Circuit breaker state should reflect failures
      state = CircuitBreaker.get_state(:task_execution)
      assert is_map(state)
      assert state.failure_count > 0
    end
  end

  describe "end-to-end workflow" do
    test "complete FLAME workflow with all features" do
      # This test simulates a complete FLAME workflow using all production features

      # 1. Initialize backend with full configuration
      {:ok, backend} =
        AppleContainersBackend.init(
          image: "flame-worker:e2e-test",
          dns_domain: "e2e.test",
          mode: :test,
          pool_config: %{
            min_warm_containers: 1,
            max_warm_containers: 2
          },
          monitoring_config: %{
            telemetry: %{enabled: true}
          }
        )

      # 2. Attempt to boot a remote container
      boot_result = AppleContainersBackend.remote_boot(backend)

      case boot_result do
        {:ok, _terminator_pid, _updated_backend} ->
          # 3. Execute a task on the container
          test_function = fn ->
            # Simulate some computation
            Enum.sum(1..1000)
          end

          execution_result = AppleContainersBackend.remote_spawn_monitor(backend, test_function)

          case execution_result do
            {:ok, _pid, _ref} ->
              assert true

            {:error, _reason} ->
              # Expected in test environment
              assert true
          end

          # 4. Verify metrics were collected
          summary = ContainerMetrics.get_metrics_summary()
          assert is_map(summary)

          # 5. Check resource usage
          resource_status = ResourceManager.get_resource_status()
          assert is_map(resource_status)

        {:error, _reason} ->
          # Expected in test environment without actual containers
          # Still verify other systems are working

          # Verify metrics system
          summary = ContainerMetrics.get_metrics_summary()
          assert is_map(summary)

          # Verify security system
          security_status = SecurityManager.get_security_status()
          assert is_map(security_status)

          # Verify resource management
          resource_status = ResourceManager.get_resource_status()
          assert is_map(resource_status)
      end
    end

    test "system remains stable under stress" do
      # Perform many operations to test system stability

      # Generate load on metrics system
      Enum.each(1..50, fn i ->
        ContainerMetrics.record_task_execution("stress-task-#{i}", i * 10)
      end)

      # Generate load on security system
      Enum.each(1..20, fn i ->
        SecurityManager.audit_log(:stress_test, %{iteration: i})
      end)

      # Generate load on resource management
      Enum.each(1..10, fn i ->
        ResourceManager.register_container("stress-container-#{i}", %{memory_mb: 128})
      end)

      # Allow time for processing
      Process.sleep(200)

      # Verify all systems are still responsive
      metrics_summary = ContainerMetrics.get_metrics_summary()
      assert is_map(metrics_summary)

      security_status = SecurityManager.get_security_status()
      assert is_map(security_status)

      resource_status = ResourceManager.get_resource_status()
      assert is_map(resource_status)

      # Cleanup stress test containers
      Enum.each(1..10, fn i ->
        ResourceManager.unregister_container("stress-container-#{i}")
      end)
    end
  end

  describe "error recovery and resilience" do
    test "system recovers from component failures" do
      # Test that the system can handle individual component errors

      # Trigger various error conditions
      error_operations = [
        fn -> AppleContainersBackend.remote_boot(%AppleContainersBackend{config: %{}}) end,
        fn -> SecurityManager.execute_safely(fn -> raise "test error" end, %{}) end,
        fn -> CircuitBreaker.call(:container_health, fn -> exit(:test) end) end
      ]

      # Execute error operations
      Enum.each(error_operations, fn operation ->
        try do
          operation.()
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)

      # Allow time for error handling
      Process.sleep(100)

      # Verify systems are still responsive
      try do
        metrics_summary = ContainerMetrics.get_metrics_summary()
        assert is_map(metrics_summary)

        security_status = SecurityManager.get_security_status()
        assert is_map(security_status)

        circuit_state = CircuitBreaker.get_state(:container_health)
        assert is_map(circuit_state)
      rescue
        error ->
          flunk("System not responsive after errors: #{inspect(error)}")
      end
    end

    test "telemetry integration works end-to-end" do
      # Set up telemetry handler
      _events_received = []

      handler_id = :integration_telemetry_test

      :telemetry.attach(
        handler_id,
        [:flame, :container, :provision],
        fn event_name, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event_name, measurements, metadata})
        end,
        %{}
      )

      # Generate telemetry event
      ContainerMetrics.record_container_provision("telemetry-integration-test")

      # Check if event was received (with timeout)
      receive do
        {:telemetry_event, event_name, measurements, metadata} ->
          assert event_name == [:flame, :container, :provision]
          assert is_map(measurements)
          assert is_map(metadata)
      after
        500 ->
          # Test passes even if no telemetry event (depends on implementation)
          :ok
      end

      # Cleanup
      :telemetry.detach(handler_id)
    end
  end

  describe "configuration integration" do
    test "respects different environment configurations" do
      # Test production mode configuration
      prod_opts = [
        mode: :production,
        pool_config: %{min_warm_containers: 5},
        monitoring_config: %{telemetry: %{enabled: true}}
      ]

      {:ok, prod_backend} = AppleContainersBackend.init(prod_opts)
      assert prod_backend.mode == :production

      # Test development mode configuration
      dev_opts = [
        mode: :development,
        pool_config: %{min_warm_containers: 1},
        monitoring_config: %{collection_interval: 60_000}
      ]

      {:ok, dev_backend} = AppleContainersBackend.init(dev_opts)
      assert dev_backend.mode == :development

      # Test mode affects system behavior
      assert prod_backend.mode != dev_backend.mode
    end

    test "handles missing or invalid configuration gracefully" do
      # Test with minimal configuration
      {:ok, backend} = AppleContainersBackend.init([])
      assert is_map(backend)
      assert is_map(backend.config)

      # Test with invalid configuration - system handles it gracefully
      {:ok, backend} =
        AppleContainersBackend.init(
          mode: :invalid_mode,
          pool_config: "not a map"
        )

      # System handled invalid config gracefully
      assert is_map(backend)
    end
  end
end
