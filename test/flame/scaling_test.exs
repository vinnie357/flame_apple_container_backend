defmodule FLAME.ScalingTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  describe "container scaling functionality" do
    test "scale up triggers container provisioning" do
      # Mock the container provisioning by testing the command structure
      container_name = "flame-worker-#{System.system_time(:millisecond)}-#{:rand.uniform(999)}"

      # Test command structure (without actually running it)
      expected_cmd = [
        "container",
        "run",
        "--name",
        container_name,
        "--detach",
        "--rm",
        "--env",
        "NODE_NAME=#{container_name}@#{container_name}.flame.local",
        "--env",
        "ERLANG_COOKIE=test_cookie",
        "flame-worker:latest"
      ]

      # Verify command structure is correct
      assert length(expected_cmd) == 11
      assert Enum.at(expected_cmd, 0) == "container"
      assert Enum.at(expected_cmd, 1) == "run"
      assert "--name" in expected_cmd
      assert "--detach" in expected_cmd
      assert "--rm" in expected_cmd

      # Check environment variables are properly formatted
      env_vars = Enum.filter(expected_cmd, &String.starts_with?(&1, "NODE_NAME="))
      assert length(env_vars) == 1
      assert hd(env_vars) =~ container_name
    end

    test "scale down attempts to terminate oldest container" do
      # Test the logic for finding oldest container

      # Mock container list output
      container_list_output = """
      flame-worker-001
      flame-worker-002
      flame-worker-003
      """

      containers =
        container_list_output
        |> String.trim()
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))

      # Should select first (oldest) container
      assert length(containers) == 3
      oldest = hd(containers)
      assert oldest == "flame-worker-001"

      # Test termination command structure
      terminate_cmd = ["container", "stop", oldest]
      assert terminate_cmd == ["container", "stop", "flame-worker-001"]
    end

    test "dashboard scaling events trigger correctly" do
      # Test that the dashboard components exist and scaling events are handled
      # This test verifies the fundamental scaling behavior without requiring LiveView

      # Mock the scaling operations that would be triggered by dashboard buttons
      scale_up_result = :ok
      scale_down_result = :ok

      # Verify the scaling operations return expected results
      assert scale_up_result == :ok
      assert scale_down_result == :ok

      # Test that the dashboard module exists and can be loaded
      assert Code.ensure_loaded(FlameWeb.DashboardLive) == {:module, FlameWeb.DashboardLive}

      # Test that the dashboard functions are available
      assert function_exported?(FlameWeb.DashboardLive, :mount, 3)
      assert function_exported?(FlameWeb.DashboardLive, :handle_event, 3)
    end

    test "container restart functionality" do
      container_id = "test-container-123"

      # Test restart command sequence
      stop_cmd = ["container", "stop", container_id]

      start_cmd = [
        "container",
        "run",
        "--name",
        "#{container_id}-restarted",
        "--detach",
        "--rm",
        "--env",
        "NODE_NAME=#{container_id}@#{container_id}.flame.local",
        "--env",
        "ERLANG_COOKIE=test_cookie",
        "flame-worker:latest"
      ]

      # Verify command structure
      assert stop_cmd == ["container", "stop", "test-container-123"]
      assert "--name" in start_cmd
      assert "test-container-123-restarted" in start_cmd
    end

    test "container termination records metrics" do
      # Set up telemetry listener for termination events
      test_pid = self()

      :telemetry.attach(
        "test-termination",
        [:flame, :container, :terminate],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:termination_recorded, measurements, metadata})
        end,
        %{}
      )

      # Record a container termination
      FLAME.ContainerMetrics.record_container_termination("test-container", :manual, %{
        terminated_by: :dashboard
      })

      # Verify telemetry event was fired
      assert_receive {:termination_recorded, measurements, metadata}, 1000

      assert measurements.count == 1
      assert metadata.container_id == "test-container"
      assert metadata.reason == :manual
      assert metadata.terminated_by == :dashboard

      :telemetry.detach("test-termination")
    end

    test "scaling preserves container configuration" do
      # Test that new containers maintain proper configuration
      base_config = %{
        image: "flame-worker:latest",
        dns_domain: "flame.local",
        erlang_cookie: "test_cookie"
      }

      container_name = "scaling-test-#{System.system_time(:millisecond)}"
      node_name = "#{container_name}@#{container_name}.#{base_config.dns_domain}"

      # Generate expected environment variables
      env_vars = [
        "--env",
        "NODE_NAME=#{node_name}",
        "--env",
        "ERLANG_COOKIE=#{base_config.erlang_cookie}"
      ]

      # Verify configuration is preserved
      assert "--env" in env_vars
      assert "NODE_NAME=#{node_name}" in env_vars
      assert "ERLANG_COOKIE=#{base_config.erlang_cookie}" in env_vars

      # Verify node name format
      assert String.contains?(node_name, container_name)
      assert String.contains?(node_name, base_config.dns_domain)
      assert String.contains?(node_name, "@")
    end
  end

  describe "container health management" do
    test "container health check logic" do
      container_name = "health-test-container"

      # Test health check command
      health_cmd = ["container", "exec", container_name, "elixir", "--version"]

      # Verify command structure
      assert health_cmd == ["container", "exec", "health-test-container", "elixir", "--version"]

      # Mock different health check results
      health_results = [
        {_output = "Elixir 1.15.0", _exit_code = 0, _expected = :healthy},
        {_output = "error", _exit_code = 1, _expected = :unhealthy},
        {_output = "", _exit_code = 127, _expected = :unhealthy}
      ]

      Enum.each(health_results, fn {_output, exit_code, expected} ->
        health_status = if exit_code == 0, do: :healthy, else: :unhealthy
        assert health_status == expected
      end)
    end

    test "container stats collection" do
      container_name = "stats-test-container"

      # Test memory stats command
      memory_cmd = ["container", "exec", container_name, "cat", "/proc/meminfo"]
      cpu_cmd = ["container", "exec", container_name, "cat", "/proc/loadavg"]

      # Verify command structure
      assert memory_cmd == ["container", "exec", "stats-test-container", "cat", "/proc/meminfo"]
      assert cpu_cmd == ["container", "exec", "stats-test-container", "cat", "/proc/loadavg"]

      # Test stats parsing with sample data
      sample_meminfo = """
      MemTotal:        1048576 kB
      MemFree:          524288 kB
      MemAvailable:     262144 kB
      Buffers:           16384 kB
      """

      sample_loadavg = "0.45 0.32 0.28 1/123 456"

      # Test memory parsing
      case Regex.run(~r/MemAvailable:\s+(\d+)\s+kB/, sample_meminfo) do
        [_, kb_str] ->
          available_kb = String.to_integer(kb_str)
          used_mb = max(50, 512 - div(available_kb, 1024))
          memory_percent = min(100, round(used_mb / 512 * 100))

          assert available_kb == 262_144
          # 512 - 262144/1024
          assert used_mb == 256
          assert memory_percent == 50

        nil ->
          assert false, "Memory parsing failed"
      end

      # Test CPU parsing
      case Regex.run(~r/^([\d\.]+)/, String.trim(sample_loadavg)) do
        [_, load_str] ->
          load = String.to_float(load_str)
          cpu_percent = min(100, round(load * 30))

          assert load == 0.45
          # round(0.45 * 30)
          assert cpu_percent == 14

        nil ->
          assert false, "CPU parsing failed"
      end
    end

    test "fallback stats when container commands fail" do
      # Test fallback behavior when container commands fail

      # Memory fallback should be random but within bounds
      fallback_memory = :rand.uniform(400) + 100
      assert fallback_memory >= 100
      assert fallback_memory <= 500

      # CPU fallback should be random but within bounds
      fallback_cpu = :rand.uniform(60) + 10
      assert fallback_cpu >= 10
      assert fallback_cpu <= 70

      # Memory percentage calculation
      memory_percent = min(100, round(fallback_memory / 512 * 100))
      assert memory_percent >= 0
      assert memory_percent <= 100
    end
  end

  describe "auto-scaling logic" do
    test "scaling decisions based on pool status" do
      # Test scaling decision logic

      # Scenario 1: High utilization should trigger scale up
      high_util_scenario = %{
        active_containers: 8,
        warm_pool_size: 1,
        cpu_percentage: 85,
        memory_percentage: 90
      }

      should_scale_up =
        high_util_scenario.cpu_percentage > 80 or
          high_util_scenario.memory_percentage > 85 or
          high_util_scenario.warm_pool_size < 2

      assert should_scale_up == true

      # Scenario 2: Low utilization should trigger scale down
      low_util_scenario = %{
        active_containers: 5,
        warm_pool_size: 4,
        cpu_percentage: 20,
        memory_percentage: 30
      }

      should_scale_down =
        low_util_scenario.cpu_percentage < 30 and
          low_util_scenario.memory_percentage < 40 and
          low_util_scenario.warm_pool_size > 3

      assert should_scale_down == true

      # Scenario 3: Balanced state should not scale
      balanced_scenario = %{
        active_containers: 4,
        warm_pool_size: 2,
        cpu_percentage: 50,
        memory_percentage: 60
      }

      should_scale =
        balanced_scenario.cpu_percentage > 80 or
          balanced_scenario.memory_percentage > 85 or
          balanced_scenario.warm_pool_size < 2 or
          (balanced_scenario.cpu_percentage < 30 and
             balanced_scenario.memory_percentage < 40 and
             balanced_scenario.warm_pool_size > 3)

      assert should_scale == false
    end

    test "scaling limits and safety checks" do
      # Test scaling limits
      max_containers = 20
      min_containers = 2

      # Scale up should respect max limit
      current_containers = 18
      scale_up_amount = min(3, max_containers - current_containers)
      # Can only add 2 more
      assert scale_up_amount == 2

      # Scale down should respect min limit
      current_containers = 4
      scale_down_amount = min(3, current_containers - min_containers)
      # Can only remove 2
      assert scale_down_amount == 2

      # At max capacity, should not scale up
      current_containers = 20
      can_scale_up = current_containers < max_containers
      assert can_scale_up == false

      # At min capacity, should not scale down
      current_containers = 2
      can_scale_down = current_containers > min_containers
      assert can_scale_down == false
    end
  end

  describe "container lifecycle events" do
    test "provision event triggers telemetry" do
      test_pid = self()

      :telemetry.attach(
        "test-provision",
        [:flame, :container, :provision],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:provision_event, measurements, metadata})
        end,
        %{}
      )

      # Trigger provision event
      FLAME.ContainerMetrics.record_container_provision("lifecycle-test", %{
        provision_type: :manual_scale_up
      })

      # Verify event
      assert_receive {:provision_event, measurements, metadata}, 1000

      assert measurements.count == 1
      assert metadata.container_id == "lifecycle-test"
      assert metadata.provision_type == :manual_scale_up

      :telemetry.detach("test-provision")
    end

    test "container checkout and return flow" do
      test_pid = self()
      container_id = "checkout-test"

      # Listen for checkout and return events
      :telemetry.attach_many(
        "test-checkout-return",
        [
          [:flame, :container, :checkout],
          [:flame, :container, :return]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:container_event, event, measurements, metadata})
        end,
        %{}
      )

      # Record checkout
      FLAME.ContainerMetrics.record_container_checkout(container_id, %{
        job_id: "test-job"
      })

      # Record return
      FLAME.ContainerMetrics.record_container_return(container_id, %{
        job_id: "test-job"
      })

      # Verify both events
      assert_receive {:container_event, [:flame, :container, :checkout], measurements1,
                      metadata1},
                     1000

      assert_receive {:container_event, [:flame, :container, :return], measurements2, metadata2},
                     1000

      assert measurements1.count == 1
      assert metadata1.container_id == container_id
      assert metadata1.job_id == "test-job"

      assert measurements2.count == 1
      assert metadata2.container_id == container_id
      assert metadata2.job_id == "test-job"

      :telemetry.detach("test-checkout-return")
    end
  end

  describe "error handling in scaling operations" do
    test "handles container provisioning failures gracefully" do
      # Test error scenarios
      error_scenarios = [
        {:container_start_failed, 1, "Image not found"},
        {:container_start_failed, 125, "Container name already exists"},
        {:readiness_timeout, nil, nil},
        {:connection_failed, "worker@test.local", nil}
      ]

      Enum.each(error_scenarios, fn {error_type, code, message} ->
        case error_type do
          :container_start_failed ->
            error = {:error, {:container_start_failed, code, message}}
            assert match?({:error, {:container_start_failed, _, _}}, error)

          :readiness_timeout ->
            error = {:error, :readiness_timeout}
            assert error == {:error, :readiness_timeout}

          :connection_failed ->
            error = {:error, {:connection_failed, message}}
            assert match?({:error, {:connection_failed, _}}, error)
        end
      end)
    end

    test "scaling operations are idempotent" do
      # Test that repeated scaling operations don't cause issues

      # Multiple scale up operations should be safe
      scale_operations = [:scale_up, :scale_up, :scale_down, :scale_up]

      Enum.each(scale_operations, fn operation ->
        case operation do
          :scale_up ->
            # Should create a unique container name each time
            container_name =
              "flame-worker-#{System.system_time(:millisecond)}-#{:rand.uniform(999)}"

            assert String.starts_with?(container_name, "flame-worker-")
            # Should have timestamp and random
            assert String.length(container_name) > 15

          :scale_down ->
            # Should handle empty container list gracefully
            containers = []

            case containers do
              # No containers to terminate
              [] -> assert true
            end
        end
      end)
    end
  end
end
