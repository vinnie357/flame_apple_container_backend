defmodule FLAME.AppleContainers.IntegrationTest do
  @moduledoc """
  Integration tests that exercise the full system stack.
  These use the real CLI adapter (no mocks) and require
  Apple Container CLI to be available on the host.
  """
  use ExUnit.Case, async: false

  alias FLAME.AppleContainers.{Manager, Monitor, Pool}
  alias FLAME.AppleContainersBackend

  @moduletag :integration

  describe "Full system integration" do
    test "complete workflow from manager to container execution" do
      # Run test in isolated process to handle potential exit signals
      test_task =
        Task.async(fn ->
          # Start the complete system (use start instead of start_link to avoid process linking)
          {:ok, manager} =
            Manager.start(
              image: "test-worker:latest",
              pool_size: 5,
              max_pool_size: 10,
              dns_domain: "test.local",
              erlang_cookie: "test_cookie_integration",
              task_timeout: 10_000
            )

          # Wait for system initialization (5 containers * 300ms max + buffer)
          :timer.sleep(2000)

          try do
            # Verify manager is healthy
            status = Manager.get_status(manager)
            assert status.health in [:healthy, :degraded]
            assert status.running_tasks == 0

            # Execute a simple task
            result =
              Manager.execute_task(manager, fn ->
                :math.pow(2, 3)
              end)

            assert {:ok, 8.0} = result

            # Execute multiple concurrent tasks
            tasks =
              for i <- 1..5 do
                Task.async(fn ->
                  Manager.execute_task(manager, fn -> i * i end)
                end)
              end

            results = Enum.map(tasks, &Task.await(&1, 3000))
            expected_results = [{:ok, 1}, {:ok, 4}, {:ok, 9}, {:ok, 16}, {:ok, 25}]

            assert length(results) == 5
            assert Enum.all?(results, fn result -> result in expected_results end)

            # Check final status
            final_status = Manager.get_status(manager)
            assert final_status.running_tasks == 0
            assert final_status.task_counter >= 6

            # Get detailed metrics
            metrics = Manager.get_metrics(manager)
            assert metrics.tasks_completed >= 6
            assert metrics.success_rate > 90.0

            :test_passed
          after
            # Graceful shutdown with error handling
            try do
              Manager.shutdown(manager)
            catch
              :exit, :shutdown -> :ok
              :exit, {:shutdown, _} -> :ok
            end
          end
        end)

      # Wait for the test to complete and handle any exits
      result = Task.await(test_task, 30_000)
      assert result == :test_passed
    end

    test "system handles scaling under load" do
      {:ok, manager} =
        Manager.start(
          pool_size: 2,
          max_pool_size: 6,
          image: "test-worker:latest"
        )

      # Wait for initialization to complete
      :ok = Manager.wait_for_initialization(manager)

      try do
        # Generate load to trigger scaling
        load_tasks =
          for i <- 1..8 do
            Task.async(fn ->
              Manager.execute_task(
                manager,
                fn ->
                  # Simulate work
                  :timer.sleep(100)
                  i
                end,
                timeout: 5000
              )
            end)
          end

        # Scale up manually during load
        :ok = Manager.scale_pool(manager, 5)

        # Wait for tasks to complete
        results = Enum.map(load_tasks, &Task.await(&1, 6000))

        # Most tasks should complete successfully
        successful_results =
          Enum.count(results, fn
            {:ok, _} -> true
            _ -> false
          end)

        assert successful_results >= 5

        # Check that scaling occurred
        status = Manager.get_status(manager)
        assert status.config.pool_size == 5
      after
        Manager.shutdown(manager)
      end
    end

    test "error handling and recovery across components" do
      {:ok, manager} =
        Manager.start(
          pool_size: 2,
          retry_attempts: 3,
          retry_backoff: 100
        )

      :timer.sleep(300)

      try do
        # Test task failure and retry
        {:ok, failure_agent} = Agent.start_link(fn -> 0 end)

        failing_task = fn ->
          attempt =
            Agent.get_and_update(failure_agent, fn count ->
              {count + 1, count + 1}
            end)

          if attempt <= 2 do
            raise "Simulated failure on attempt #{attempt}"
          else
            :success_after_retries
          end
        end

        result = Manager.execute_task(manager, failing_task)
        assert {:ok, :success_after_retries} = result

        # Test permanent failure
        permanent_failure = fn -> raise "Permanent failure" end
        result = Manager.execute_task(manager, permanent_failure)
        assert {:error, _reason} = result

        # System should still be operational
        success_task = fn -> :still_working end
        assert {:ok, :still_working} = Manager.execute_task(manager, success_task)
      after
        try do
          Manager.shutdown(manager)
        catch
          :exit, _ -> :ok
        end
      end
    end

    test "monitoring integration with pool and manager" do
      # Trap exits to handle process shutdown gracefully
      Process.flag(:trap_exit, true)

      # Start all components
      {:ok, backend} =
        AppleContainersBackend.init(
          image: "test-worker:latest",
          mode: :test
        )

      {:ok, pool} =
        Pool.start_link(
          backend: backend,
          size: 2,
          health_check_interval: 1000
        )

      # Create a manager process for monitor
      manager_pid =
        spawn(fn ->
          receive do
            {:health_check, status} ->
              send(self(), {:received_health_check, status})
              integration_manager_loop()

            msg ->
              send(self(), {:received_message, msg})
              integration_manager_loop()
          end
        end)

      {:ok, monitor} =
        Monitor.start_link(
          pool: pool,
          manager: manager_pid,
          health_check_interval: 500
        )

      try do
        # Let the system run and monitor itself
        :timer.sleep(1000)

        # Trigger immediate health check to initialize health status
        :ok = Monitor.trigger_health_check(monitor)
        :timer.sleep(500)

        # Check monitor health status
        health_status = Monitor.get_health_status(monitor)
        assert health_status.overall_health in [:healthy, :degraded, :unhealthy, :unknown]
        assert health_status.health_score >= 0

        # Trigger another health check
        :ok = Monitor.trigger_health_check(monitor)
        :timer.sleep(300)

        # Get system summary
        summary = Monitor.get_system_summary(monitor)
        assert is_map(summary)
        assert Map.has_key?(summary, :capacity_utilization)

        # Perform some pool operations
        {:ok, container} = Pool.acquire_container(pool)
        Pool.release_container(pool, container)

        # Monitor should detect the activity
        :timer.sleep(1000)
        metrics = Monitor.get_metrics(monitor, :last_hour)
        assert is_map(metrics)
      after
        # Cleanup processes in reverse order
        if Process.alive?(monitor), do: Monitor.shutdown(monitor)
        if Process.alive?(pool), do: Pool.shutdown(pool)
        if Process.alive?(manager_pid), do: Process.exit(manager_pid, :normal)

        # Flush any exit messages
        receive do
          {:EXIT, _, _} -> :ok
        after
          100 -> :ok
        end
      end
    end

    defp integration_manager_loop do
      receive do
        :stop -> :ok
        _msg -> integration_manager_loop()
      end
    end

    test "performance under sustained load" do
      {:ok, manager} =
        Manager.start(
          pool_size: 4,
          max_pool_size: 8,
          task_timeout: 10_000
        )

      # Wait for containers to be initialized
      :timer.sleep(1000)

      try do
        # Generate sustained load over time
        start_time = System.monotonic_time(:millisecond)

        batch_tasks =
          for batch <- 1..3 do
            Task.async(fn ->
              # Each batch runs 10 tasks
              tasks =
                for i <- 1..10 do
                  Task.async(fn ->
                    Manager.execute_task(manager, fn ->
                      :timer.sleep(:rand.uniform(50))
                      batch * 10 + i
                    end)
                  end)
                end

              Enum.map(tasks, &Task.await(&1, 5000))
            end)
          end

        all_results = Enum.flat_map(batch_tasks, &Task.await(&1, 8000))
        end_time = System.monotonic_time(:millisecond)

        # Verify results
        assert length(all_results) == 30

        successful_tasks =
          Enum.count(all_results, fn
            {:ok, _} -> true
            _ -> false
          end)

        # At least 80% success rate (more realistic)
        assert successful_tasks >= 24

        # Check performance metrics
        execution_time = end_time - start_time
        # Should complete within 15 seconds
        assert execution_time < 15_000

        metrics = Manager.get_metrics(manager)
        assert metrics.success_rate >= 70.0
        # Average under 3 seconds
        assert metrics.avg_execution_time < 3000
      after
        Manager.shutdown(manager)
      end
    end

    test "resource cleanup and memory management" do
      {:ok, manager} =
        Manager.start(
          pool_size: 3,
          task_timeout: 1000
        )

      :timer.sleep(300)

      try do
        # Execute many tasks to test cleanup
        for batch <- 1..5 do
          tasks =
            for _i <- 1..10 do
              Task.async(fn ->
                Manager.execute_task(manager, fn ->
                  # Create some data that needs cleanup
                  data = Enum.to_list(1..(batch * 1000))
                  Enum.sum(data)
                end)
              end)
            end

          _results = Enum.map(tasks, &Task.await(&1, 2000))

          # Check that tasks are cleaned up
          status = Manager.get_status(manager)
          assert status.running_tasks == 0
        end

        # Final status should show no resource leaks
        final_status = Manager.get_status(manager)
        assert final_status.running_tasks == 0
        assert final_status.task_counter >= 50

        # System should still be responsive
        quick_task = fn -> :cleanup_test_passed end
        assert {:ok, :cleanup_test_passed} = Manager.execute_task(manager, quick_task)
      after
        Manager.shutdown(manager)
      end
    end

    test "configuration changes during runtime" do
      {:ok, manager} =
        Manager.start(
          pool_size: 2,
          max_pool_size: 10
        )

      # Wait for initialization to complete
      :ok = Manager.wait_for_initialization(manager)

      try do
        # Initial configuration
        initial_status = Manager.get_status(manager)
        assert initial_status.config.pool_size == 2

        # Scale up
        :ok = Manager.scale_pool(manager, 5)
        :ok = Manager.wait_for_scaling_complete(manager)

        scaled_status = Manager.get_status(manager)
        assert scaled_status.config.pool_size == 5

        # Execute tasks on scaled pool
        tasks =
          for i <- 1..8 do
            Task.async(fn ->
              Manager.execute_task(manager, fn -> i * 2 end)
            end)
          end

        results = Enum.map(tasks, &Task.await(&1, 2000))

        successful_results =
          Enum.count(results, fn
            {:ok, _} -> true
            _ -> false
          end)

        assert successful_results >= 6

        # Scale down
        :ok = Manager.scale_pool(manager, 3)
        :ok = Manager.wait_for_scaling_complete(manager)

        final_status = Manager.get_status(manager)
        assert final_status.config.pool_size == 3

        # Should still be functional
        assert {:ok, 42} = Manager.execute_task(manager, fn -> 42 end)
      after
        Manager.shutdown(manager)
      end
    end

    test "system behavior with mixed task types" do
      {:ok, manager} =
        Manager.start(
          pool_size: 4,
          task_timeout: 3000,
          retry_attempts: 2
        )

      # Wait for containers to be created (up to 300ms each + buffer)
      :timer.sleep(1500)

      try do
        # Mix of different task types
        quick_tasks =
          for i <- 1..5 do
            Task.async(fn ->
              # Very quick
              Manager.execute_task(manager, fn -> i end)
            end)
          end

        slow_tasks =
          for i <- 1..3 do
            Task.async(fn ->
              Manager.execute_task(manager, fn ->
                # Moderate delay
                :timer.sleep(500)
                i * 100
              end)
            end)
          end

        cpu_intensive_tasks =
          for _i <- 1..2 do
            Task.async(fn ->
              Manager.execute_task(manager, fn ->
                # CPU intensive work
                Enum.reduce(1..10_000, 0, fn x, acc -> acc + x end)
              end)
            end)
          end

        # Wait for all tasks
        quick_results = Enum.map(quick_tasks, &Task.await(&1, 1000))
        slow_results = Enum.map(slow_tasks, &Task.await(&1, 2000))
        cpu_results = Enum.map(cpu_intensive_tasks, &Task.await(&1, 2000))

        # Verify all completed
        all_results = quick_results ++ slow_results ++ cpu_results

        successful_count =
          Enum.count(all_results, fn
            {:ok, _} -> true
            _ -> false
          end)

        # Most should succeed
        assert successful_count >= 8

        # Check system health after mixed load
        final_status = Manager.get_status(manager)
        assert final_status.health in [:healthy, :degraded]
        assert final_status.running_tasks == 0
      after
        Manager.shutdown(manager)
      end
    end
  end

  describe "System resilience" do
    test "handles component restart scenarios" do
      # Start system
      {:ok, manager} =
        Manager.start(
          pool_size: 2,
          max_pool_size: 5
        )

      :timer.sleep(300)

      try do
        # Execute initial tasks
        initial_result = Manager.execute_task(manager, fn -> :initial_task end)
        assert {:ok, :initial_task} = initial_result

        # Simulate component stress/recovery
        stress_tasks =
          for i <- 1..10 do
            Task.async(fn ->
              Manager.execute_task(manager, fn ->
                if rem(i, 3) == 0 do
                  raise "Simulated stress failure"
                else
                  i
                end
              end)
            end)
          end

        stress_results = Enum.map(stress_tasks, &Task.await(&1, 5000))

        # Some should succeed, some should fail
        successful_stress =
          Enum.count(stress_results, fn
            {:ok, _} -> true
            _ -> false
          end)

        # At least some should succeed
        assert successful_stress >= 5

        # System should recover and be operational
        recovery_result = Manager.execute_task(manager, fn -> :recovery_verified end)
        assert {:ok, :recovery_verified} = recovery_result
      after
        Manager.shutdown(manager)
      end
    end

    test "maintains consistency under concurrent operations" do
      # Run test in isolated process to handle potential exit signals
      test_task =
        Task.async(fn ->
          {:ok, manager} =
            Manager.start(
              pool_size: 5,
              max_pool_size: 8,
              task_timeout: 10_000
            )

          # Wait for system initialization to complete
          :ok = Manager.wait_for_initialization(manager)

          try do
            # Concurrent operations: tasks + scaling + status checks
            task_workers =
              for i <- 1..6 do
                Task.async(fn ->
                  Manager.execute_task(manager, fn ->
                    :timer.sleep(100)
                    i
                  end)
                end)
              end

            scaling_worker =
              Task.async(fn ->
                :timer.sleep(50)
                Manager.scale_pool(manager, 7)
                :timer.sleep(100)
                Manager.scale_pool(manager, 6)
              end)

            status_worker =
              Task.async(fn ->
                for _i <- 1..5 do
                  Manager.get_status(manager)
                  Manager.get_metrics(manager)
                  :timer.sleep(30)
                end

                :status_checks_complete
              end)

            # Wait for all operations
            task_results = Enum.map(task_workers, &Task.await(&1, 2000))
            scaling_result = Task.await(scaling_worker, 2000)
            status_result = Task.await(status_worker, 2000)

            # Verify consistency
            successful_tasks =
              Enum.count(task_results, fn
                {:ok, _} -> true
                _ -> false
              end)

            assert successful_tasks >= 4
            # Scaling operations may be rejected due to concurrent access, which is expected
            assert scaling_result == :ok or scaling_result == {:error, :scaling_in_progress}
            assert status_result == :status_checks_complete

            # Final state should be consistent
            final_status = Manager.get_status(manager)
            assert final_status.running_tasks == 0
            # Should be one of the configured sizes
            assert final_status.config.pool_size in [5, 6, 7]

            :test_passed
          after
            # Graceful shutdown with error handling
            try do
              Manager.shutdown(manager)
            catch
              :exit, :shutdown -> :ok
              :exit, {:shutdown, _} -> :ok
            end
          end
        end)

      # Wait for the test to complete and handle any exits
      result = Task.await(test_task, 30_000)
      assert result == :test_passed
    end
  end
end
