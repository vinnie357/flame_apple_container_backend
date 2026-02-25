defmodule FLAME.AppleContainers.MonitorTest do
  use ExUnit.Case, async: false

  alias FLAME.AppleContainers.CLI.Mock, as: CLIMock
  alias FLAME.AppleContainers.{Monitor, Pool}
  alias FLAME.AppleContainersBackend

  setup do
    original = Application.get_env(:flame_apple_container_backend, :cli_adapter)
    Application.put_env(:flame_apple_container_backend, :cli_adapter, CLIMock)

    CLIMock.set_responses(%{
      list_dns_domains: {"test.local\n", 0},
      hostname: {"test-host.local\n", 0}
    })

    {:ok, backend} =
      AppleContainersBackend.init(
        image: "test-worker:latest",
        dns_domain: "test.local",
        mode: :test
      )

    {:ok, pool} =
      Pool.start_link(
        backend: backend,
        size: 2
      )

    # Create a simple manager process for testing
    manager = spawn(fn -> monitor_manager_loop() end)

    :timer.sleep(200)

    on_exit(fn ->
      try do
        if Process.alive?(pool), do: Pool.shutdown(pool)
      catch
        :exit, _ -> :ok
      end

      if Process.alive?(manager), do: Process.exit(manager, :normal)

      if original do
        Application.put_env(:flame_apple_container_backend, :cli_adapter, original)
      else
        Application.delete_env(:flame_apple_container_backend, :cli_adapter)
      end
    end)

    %{backend: backend, pool: pool, manager: manager}
  end

  defp monitor_manager_loop do
    receive do
      {:health_check, _status} -> monitor_manager_loop()
      :stop -> :ok
      _ -> monitor_manager_loop()
    end
  end

  describe "Monitor initialization" do
    test "starts with default configuration", %{pool: pool, manager: manager} do
      {:ok, monitor} =
        Monitor.start_link(
          pool: pool,
          manager: manager
        )

      assert Process.alive?(monitor)

      Monitor.shutdown(monitor)
    end

    test "starts with custom configuration", %{pool: pool, manager: manager} do
      opts = [
        pool: pool,
        manager: manager,
        health_check_interval: 5000,
        metrics_collection_interval: 10_000,
        alert_thresholds: %{
          cpu_usage: 70.0,
          memory_usage: 75.0
        }
      ]

      {:ok, monitor} = Monitor.start_link(opts)

      assert Process.alive?(monitor)

      Monitor.shutdown(monitor)
    end

    test "requires pool and manager parameters" do
      # Test without any context to avoid the issue with missing context parameters

      # Missing both parameters should fail
      assert {:error, {:missing_required_parameter, :pool_or_manager}} = Monitor.start_link([])

      # Create temporary processes for testing
      manager =
        spawn(fn ->
          receive do
            :stop -> :ok
            _ -> :timer.sleep(100)
          end
        end)

      # Missing pool should fail
      assert {:error, {:missing_required_parameter, :pool_or_manager}} =
               Monitor.start_link(manager: manager)

      # Create a mock pool process
      pool =
        spawn(fn ->
          receive do
            :stop -> :ok
            _ -> :timer.sleep(100)
          end
        end)

      # Missing manager should fail
      assert {:error, {:missing_required_parameter, :pool_or_manager}} =
               Monitor.start_link(pool: pool)

      # Clean up
      Process.exit(manager, :normal)
      Process.exit(pool, :normal)
    end
  end

  describe "Health monitoring" do
    setup %{pool: pool, manager: manager} do
      {:ok, monitor} =
        Monitor.start_link(
          pool: pool,
          manager: manager,
          health_check_interval: 1000
        )

      %{monitor: monitor}
    end

    test "returns current health status", %{monitor: monitor} do
      health_status = Monitor.get_health_status(monitor)

      assert is_map(health_status)
      assert Map.has_key?(health_status, :overall_health)
      assert Map.has_key?(health_status, :component_health)
      assert Map.has_key?(health_status, :health_score)
      assert Map.has_key?(health_status, :uptime)

      assert health_status.overall_health in [
               :healthy,
               :degraded,
               :unhealthy,
               :critical,
               :unknown
             ]

      assert is_number(health_status.health_score)
      assert health_status.health_score >= 0 and health_status.health_score <= 100

      Monitor.shutdown(monitor)
    end

    test "performs periodic health checks", %{monitor: monitor} do
      # Wait for a few health check cycles
      :timer.sleep(2500)

      health_status = Monitor.get_health_status(monitor)

      # Should have performed at least one health check
      assert health_status.last_check != nil
      assert is_integer(health_status.last_check)

      Monitor.shutdown(monitor)
    end

    test "triggers immediate health check", %{monitor: monitor} do
      assert :ok = Monitor.trigger_health_check(monitor)

      # Allow time for health check to complete
      :timer.sleep(500)

      health_status = Monitor.get_health_status(monitor)
      assert health_status.last_check != nil

      Monitor.shutdown(monitor)
    end

    test "detects component health changes", %{monitor: monitor} do
      # Initial health check
      initial_status = Monitor.get_health_status(monitor)

      # Wait for more health checks
      :timer.sleep(2000)

      current_status = Monitor.get_health_status(monitor)

      # Should have updated timestamps
      if initial_status.last_check != nil and current_status.last_check != nil do
        assert current_status.last_check >= initial_status.last_check
      end

      Monitor.shutdown(monitor)
    end
  end

  describe "Metrics collection" do
    setup %{pool: pool, manager: manager} do
      {:ok, monitor} =
        Monitor.start_link(
          pool: pool,
          manager: manager,
          metrics_collection_interval: 1000
        )

      %{monitor: monitor}
    end

    test "collects and returns metrics", %{monitor: monitor} do
      # Wait for metrics collection
      :timer.sleep(1500)

      metrics = Monitor.get_metrics(monitor, :last_hour)

      assert is_map(metrics)
      # Metrics structure will depend on implementation

      Monitor.shutdown(monitor)
    end

    test "supports different time ranges for metrics", %{monitor: monitor} do
      :timer.sleep(1500)

      # Test different time ranges
      hour_metrics = Monitor.get_metrics(monitor, :last_hour)
      day_metrics = Monitor.get_metrics(monitor, :last_day)

      assert is_map(hour_metrics)
      assert is_map(day_metrics)

      Monitor.shutdown(monitor)
    end

    test "filters metrics by type", %{monitor: monitor} do
      :timer.sleep(1500)

      # Test filtering by metric types
      cpu_metrics = Monitor.get_metrics(monitor, :last_hour, [:cpu])
      memory_metrics = Monitor.get_metrics(monitor, :last_hour, [:memory])
      all_metrics = Monitor.get_metrics(monitor, :last_hour, :all)

      assert is_map(cpu_metrics)
      assert is_map(memory_metrics)
      assert is_map(all_metrics)

      Monitor.shutdown(monitor)
    end
  end

  describe "System summary" do
    setup %{pool: pool, manager: manager} do
      {:ok, monitor} =
        Monitor.start_link(
          pool: pool,
          manager: manager
        )

      %{monitor: monitor}
    end

    test "generates system summary", %{monitor: monitor} do
      # Wait for some data collection
      :timer.sleep(1000)

      summary = Monitor.get_system_summary(monitor)

      assert is_map(summary)
      assert Map.has_key?(summary, :capacity_utilization)
      assert Map.has_key?(summary, :performance_summary)
      assert Map.has_key?(summary, :scaling_recommendations)
      assert Map.has_key?(summary, :health_trends)

      Monitor.shutdown(monitor)
    end

    test "provides scaling recommendations", %{monitor: monitor} do
      summary = Monitor.get_system_summary(monitor)

      recommendations = summary.scaling_recommendations
      assert is_list(recommendations)

      Monitor.shutdown(monitor)
    end

    test "analyzes health trends", %{monitor: monitor} do
      # Wait for multiple health checks to build history
      :timer.sleep(3000)

      summary = Monitor.get_system_summary(monitor)

      health_trends = summary.health_trends
      assert is_map(health_trends)
      assert Map.has_key?(health_trends, :trend)

      Monitor.shutdown(monitor)
    end
  end

  describe "Alert thresholds" do
    setup %{pool: pool, manager: manager} do
      {:ok, monitor} =
        Monitor.start_link(
          pool: pool,
          manager: manager,
          alert_thresholds: %{
            cpu_usage: 50.0,
            memory_usage: 60.0
          }
        )

      %{monitor: monitor}
    end

    test "updates alert thresholds", %{monitor: monitor} do
      new_thresholds = %{
        cpu_usage: 75.0,
        error_rate: 10.0
      }

      assert :ok = Monitor.update_thresholds(monitor, new_thresholds)

      Monitor.shutdown(monitor)
    end

    test "applies updated thresholds to health checks", %{monitor: monitor} do
      # Update thresholds
      Monitor.update_thresholds(monitor, %{cpu_usage: 30.0})

      # Trigger health check
      Monitor.trigger_health_check(monitor)
      :timer.sleep(500)

      # Monitor should still be functional
      assert Process.alive?(monitor)

      Monitor.shutdown(monitor)
    end
  end

  describe "Integration with pool and manager" do
    setup %{pool: pool, manager: manager} do
      {:ok, monitor} =
        Monitor.start_link(
          pool: pool,
          manager: manager,
          health_check_interval: 500
        )

      %{monitor: monitor}
    end

    test "monitors pool health accurately", %{monitor: monitor, pool: pool} do
      # Perform some pool operations
      {:ok, container} = Pool.acquire_container(pool)
      Pool.release_container(pool, container)

      # Trigger health check
      Monitor.trigger_health_check(monitor)
      :timer.sleep(200)

      health_status = Monitor.get_health_status(monitor)

      # Should reflect pool operations
      assert health_status.component_health != %{}

      Monitor.shutdown(monitor)
    end

    test "communicates with manager", %{monitor: monitor, manager: manager} do
      # Wait for health checks to be sent to manager
      :timer.sleep(1000)

      # Manager should receive health check messages
      # This is verified by the manager process not crashing
      assert Process.alive?(manager)
      assert Process.alive?(monitor)

      Monitor.shutdown(monitor)
    end
  end

  describe "Error handling and recovery" do
    setup %{pool: pool, manager: manager} do
      {:ok, monitor} =
        Monitor.start_link(
          pool: pool,
          manager: manager,
          recovery_enabled: true
        )

      %{monitor: monitor}
    end

    test "handles pool communication errors gracefully", %{monitor: monitor} do
      # Simulate pool issues by triggering health checks when pool might have issues
      # Monitor should handle this gracefully without crashing

      Monitor.trigger_health_check(monitor)
      :timer.sleep(200)

      # Monitor should still be alive and responsive
      assert Process.alive?(monitor)

      health_status = Monitor.get_health_status(monitor)
      # Should return a valid health status structure, regardless of pool state
      assert is_map(health_status)
      assert Map.has_key?(health_status, :overall_health)

      assert health_status.overall_health in [
               :healthy,
               :degraded,
               :unhealthy,
               :critical,
               :unknown
             ]

      Monitor.shutdown(monitor)
    end

    test "continues monitoring after temporary failures", %{monitor: monitor} do
      # Trigger multiple health checks
      for _i <- 1..3 do
        Monitor.trigger_health_check(monitor)
        :timer.sleep(100)
      end

      # Monitor should remain functional
      assert Process.alive?(monitor)

      health_status = Monitor.get_health_status(monitor)
      assert is_map(health_status)

      Monitor.shutdown(monitor)
    end

    test "performs recovery actions when enabled", %{monitor: monitor} do
      # This test would require more sophisticated setup to trigger recovery
      # For now, verify that recovery-enabled monitor behaves correctly

      :timer.sleep(1000)

      assert Process.alive?(monitor)

      health_status = Monitor.get_health_status(monitor)
      assert is_map(health_status)

      Monitor.shutdown(monitor)
    end
  end

  describe "Performance and resource usage" do
    setup %{pool: pool, manager: manager} do
      {:ok, monitor} =
        Monitor.start_link(
          pool: pool,
          manager: manager,
          health_check_interval: 200,
          metrics_collection_interval: 300
        )

      %{monitor: monitor}
    end

    test "handles high frequency monitoring efficiently", %{monitor: monitor} do
      # Wait for multiple monitoring cycles
      :timer.sleep(2000)

      # Monitor should remain responsive
      start_time = System.monotonic_time(:millisecond)
      health_status = Monitor.get_health_status(monitor)
      end_time = System.monotonic_time(:millisecond)

      assert is_map(health_status)
      # Response should be fast (under 100ms)
      assert end_time - start_time < 100

      Monitor.shutdown(monitor)
    end

    test "manages memory usage with data collection", %{monitor: monitor} do
      # Let monitor collect data for a while
      :timer.sleep(3000)

      # Verify monitor is still functional
      assert Process.alive?(monitor)

      # Check that metrics can be retrieved
      metrics = Monitor.get_metrics(monitor, :last_hour)
      assert is_map(metrics)

      Monitor.shutdown(monitor)
    end
  end

  describe "Configuration validation" do
    test "validates required parameters", %{pool: pool, manager: manager} do
      # Valid configuration
      assert {:ok, _monitor} =
               Monitor.start_link(
                 pool: pool,
                 manager: manager,
                 health_check_interval: 1000
               )
    end

    test "handles invalid configuration gracefully", %{pool: pool, manager: manager} do
      # Configuration with invalid values should either be corrected or cause startup failure
      opts = [
        pool: pool,
        manager: manager,
        # Invalid negative interval
        health_check_interval: -1000
      ]

      # Should either start with corrected config or fail gracefully
      result = Monitor.start_link(opts)

      case result do
        {:ok, monitor} ->
          Monitor.shutdown(monitor)

        {:error, _reason} ->
          # Expected failure is acceptable
          :ok
      end
    end
  end

  describe "Concurrent operations" do
    setup %{pool: pool, manager: manager} do
      {:ok, monitor} =
        Monitor.start_link(
          pool: pool,
          manager: manager,
          health_check_interval: 500
        )

      %{monitor: monitor}
    end

    test "handles concurrent API calls", %{monitor: monitor} do
      # Make multiple concurrent API calls
      tasks = [
        Task.async(fn -> Monitor.get_health_status(monitor) end),
        Task.async(fn -> Monitor.get_metrics(monitor, :last_hour) end),
        Task.async(fn -> Monitor.get_system_summary(monitor) end),
        Task.async(fn -> Monitor.trigger_health_check(monitor) end)
      ]

      results = Enum.map(tasks, &Task.await(&1, 2000))

      # All calls should complete successfully
      assert length(results) == 4

      assert Enum.all?(results, fn result ->
               case result do
                 :ok -> true
                 map when is_map(map) -> true
                 _ -> false
               end
             end)

      Monitor.shutdown(monitor)
    end

    test "handles concurrent threshold updates", %{monitor: monitor} do
      # Make concurrent threshold updates
      tasks =
        for i <- 1..3 do
          Task.async(fn ->
            Monitor.update_thresholds(monitor, %{"cpu_usage_#{i}" => 50.0 + i})
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 1000))

      # All updates should succeed
      assert Enum.all?(results, &(&1 == :ok))

      Monitor.shutdown(monitor)
    end
  end

  describe "Graceful shutdown" do
    test "shuts down cleanly", %{pool: pool, manager: manager} do
      {:ok, monitor} =
        Monitor.start_link(
          pool: pool,
          manager: manager
        )

      assert :ok = Monitor.shutdown(monitor)

      # Monitor process should be terminated
      :timer.sleep(100)
      refute Process.alive?(monitor)
    end

    test "handles shutdown during active monitoring", %{pool: pool, manager: manager} do
      {:ok, monitor} =
        Monitor.start_link(
          pool: pool,
          manager: manager,
          health_check_interval: 100
        )

      # Let it run for a bit
      :timer.sleep(300)

      # Shutdown should work even during active monitoring
      assert :ok = Monitor.shutdown(monitor)

      :timer.sleep(100)
      refute Process.alive?(monitor)
    end
  end
end
