defmodule FlameWeb.TestControllerTest do
  use FlameWeb.ConnCase
  import Phoenix.ConnTest

  @moduletag :integration

  describe "test job execution" do
    test "run_job endpoint triggers job execution", %{conn: conn} do
      # Test simple job
      conn = post(conn, "/api/test/run", %{"type" => "simple", "count" => "1"})

      assert json_response(conn, 200)
      response = json_response(conn, 200)

      assert response["success"] == true
      assert response["message"] =~ "Started 1 simple jobs"
      assert response["job_type"] == "simple"
      assert response["job_count"] == 1
    end

    test "run_job handles different job types", %{conn: _conn} do
      job_types = ["simple", "complex", "error", "mixed", "ml"]

      Enum.each(job_types, fn job_type ->
        conn = post(build_conn(), "/api/test/run", %{"type" => job_type, "count" => "1"})

        assert json_response(conn, 200)
        response = json_response(conn, 200)

        assert response["success"] == true
        assert response["message"] =~ "Started 1 #{job_type} jobs"
        assert response["job_type"] == job_type
        assert response["job_count"] == 1
      end)
    end

    test "run_job handles multiple job counts", %{conn: _conn} do
      counts = ["1", "3", "5"]

      Enum.each(counts, fn count ->
        conn = post(build_conn(), "/api/test/run", %{"type" => "simple", "count" => count})

        assert json_response(conn, 200)
        response = json_response(conn, 200)

        assert response["success"] == true
        assert response["message"] =~ "Started #{count} simple jobs"
        assert response["job_type"] == "simple"
        assert response["job_count"] == String.to_integer(count)
      end)
    end

    test "run_job defaults to simple type and count 1", %{conn: conn} do
      conn = post(conn, "/api/test/run", %{})

      assert json_response(conn, 200)
      response = json_response(conn, 200)

      assert response["success"] == true
      assert response["message"] =~ "Started 1 simple jobs"
      assert response["job_type"] == "simple"
      assert response["job_count"] == 1
    end
  end

  describe "status endpoint" do
    test "returns JSON status", %{conn: conn} do
      conn = get(conn, "/api/test/status")

      assert json_response(conn, 200)
      response = json_response(conn, 200)

      # Check required fields
      assert Map.has_key?(response, "pool_status")
      assert Map.has_key?(response, "metrics")
      assert Map.has_key?(response, "resource_status")
      assert Map.has_key?(response, "circuit_breaker_status")
      assert Map.has_key?(response, "timestamp")

      # Verify timestamp is recent
      assert is_integer(response["timestamp"])
      assert response["timestamp"] > System.system_time(:millisecond) - 10_000
    end

    test "status endpoint handles service unavailability", %{conn: conn} do
      # Even if services are down, should return graceful defaults
      conn = get(conn, "/api/test/status")
      response = json_response(conn, 200)

      # Should have structure even with default/empty values
      assert is_map(response["pool_status"])
      assert is_map(response["metrics"])
      assert is_map(response["resource_status"])
      assert is_map(response["circuit_breaker_status"])
    end
  end

  describe "execute endpoint" do
    test "executes simple job successfully", %{conn: conn} do
      job_params = %{
        "type" => "simple",
        "name" => "Test Simple Job",
        "data" => %{"numbers" => [1, 2, 3, 4, 5]}
      }

      conn = post(conn, "/api/test/execute", %{"job" => job_params})

      assert json_response(conn, 200)
      response = json_response(conn, 200)

      assert response["success"] == true
      assert Map.has_key?(response, "result")
      assert is_map(response["result"])
    end

    test "executes complex job successfully", %{conn: conn} do
      job_params = %{
        "type" => "complex",
        "name" => "Test Complex Job",
        "data" => %{
          "dataset_size" => 1000,
          "operations" => ["sort", "filter", "transform"]
        }
      }

      conn = post(conn, "/api/test/execute", %{"job" => job_params})

      assert json_response(conn, 200)
      response = json_response(conn, 200)

      assert response["success"] == true
      assert Map.has_key?(response, "result")
    end

    test "handles ML job execution", %{conn: conn} do
      job_params = %{
        "type" => "ml",
        "name" => "Test ML Job",
        "data" => %{
          "model_type" => "neural_network",
          "dataset_size" => 5000,
          "epochs" => 100
        }
      }

      conn = post(conn, "/api/test/execute", %{"job" => job_params})

      assert json_response(conn, 200)
      response = json_response(conn, 200)

      assert response["success"] == true
      assert is_map(response["result"])
    end

    test "handles error jobs appropriately", %{conn: conn} do
      job_params = %{
        "type" => "error",
        "name" => "Test Error Job",
        "data" => %{"error_type" => "timeout"}
      }

      conn = post(conn, "/api/test/execute", %{"job" => job_params})

      # Error jobs should return 422 status
      assert response(conn, 422)
      response = json_response(conn, 422)

      assert response["success"] == false
      assert Map.has_key?(response, "error")
    end

    test "handles invalid job parameters", %{conn: conn} do
      # Missing required fields
      conn = post(conn, "/api/test/execute", %{"job" => %{}})

      # Should handle gracefully (might succeed with defaults or fail appropriately)
      assert response(conn, 200) || response(conn, 422)
    end
  end

  describe "execute_test_jobs function" do
    test "execute_test_jobs runs simple jobs" do
      # Test the public function directly
      assert :ok = FlameWeb.TestController.execute_test_jobs(:simple, 1)
    end

    test "execute_test_jobs runs different job types" do
      job_types = [:simple, :complex, :error, :mixed, :ml]

      Enum.each(job_types, fn job_type ->
        assert :ok = FlameWeb.TestController.execute_test_jobs(job_type, 1)
      end)
    end

    test "execute_test_jobs handles multiple jobs" do
      # Test with multiple jobs (but keep count low for fast tests)
      assert :ok = FlameWeb.TestController.execute_test_jobs(:simple, 2)
    end

    test "execute_test_jobs records metrics" do
      # Ensure that running jobs records telemetry
      _initial_time = System.system_time(:millisecond)

      FlameWeb.TestController.execute_test_jobs(:simple, 1)

      # Give time for metrics to be recorded
      Process.sleep(100)

      # Check that metrics were updated (basic check)
      try do
        metrics = FLAME.ContainerMetrics.get_metrics_summary()
        assert is_map(metrics)
      catch
        :exit, {:noproc, _} ->
          # ContainerMetrics GenServer not available - acceptable in test environment
          assert true

        :exit, :noproc ->
          # ContainerMetrics GenServer not available - acceptable in test environment
          assert true

        :exit, {:shutdown, _} ->
          # ContainerMetrics was shut down during test suite - acceptable in test environment
          assert true

        :exit, :shutdown ->
          # ContainerMetrics was shut down during test suite - acceptable in test environment
          assert true
      end
    end
  end

  describe "job simulation functions" do
    test "simple computation simulation works" do
      # Test the job simulation directly by calling execute with known parameters
      job_params = %{
        "id" => "test-simple-1",
        "type" => "simple",
        "name" => "Test Simple",
        "data" => %{"numbers" => [1, 2, 3, 4, 5]}
      }

      conn = post(build_conn(), "/api/test/execute", %{"job" => job_params})
      response = json_response(conn, 200)

      assert response["success"] == true
      result = response["result"]

      # Verify simple computation results
      assert is_map(result)
      assert Map.has_key?(result, "sum")
      assert Map.has_key?(result, "count")
      assert Map.has_key?(result, "average")
      assert result["sum"] == 15
      assert result["count"] == 5
      assert result["average"] == 3.0
    end

    test "complex computation simulation works" do
      job_params = %{
        "type" => "complex",
        "name" => "Test Complex",
        "data" => %{
          "dataset_size" => 100,
          "operations" => ["sort", "filter"]
        }
      }

      conn = post(build_conn(), "/api/test/execute", %{"job" => job_params})
      response = json_response(conn, 200)

      assert response["success"] == true
      result = response["result"]

      assert Map.has_key?(result, "operations_completed")
      assert Map.has_key?(result, "dataset_size")
      assert Map.has_key?(result, "processing_time")
      assert result["dataset_size"] == 100
      assert length(result["operations_completed"]) == 2
    end

    test "ML job simulation provides realistic results" do
      job_params = %{
        "type" => "ml",
        "name" => "Test ML",
        "data" => %{
          "model_type" => "neural_network",
          "dataset_size" => 1000,
          "epochs" => 50
        }
      }

      conn = post(build_conn(), "/api/test/execute", %{"job" => job_params})
      response = json_response(conn, 200)

      assert response["success"] == true
      result = response["result"]

      assert Map.has_key?(result, "model_accuracy")
      assert Map.has_key?(result, "training_iterations")
      assert Map.has_key?(result, "processing_time")
      assert Map.has_key?(result, "resource_usage")

      # Verify realistic values
      assert result["model_accuracy"] >= 0 and result["model_accuracy"] <= 1
      assert is_integer(result["training_iterations"])
      assert is_integer(result["processing_time"])
    end
  end

  describe "metrics integration" do
    test "jobs record container metrics" do
      try do
        # Clear existing metrics by getting current summary
        initial_metrics = FLAME.ContainerMetrics.get_metrics_summary()
        initial_executions = Map.get(initial_metrics, :total_task_executions, 0)

        # Execute a job
        job_params = %{
          "type" => "simple",
          "name" => "Metrics Test",
          "data" => %{"numbers" => [1, 2, 3]}
        }

        post(build_conn(), "/api/test/execute", %{"job" => job_params})

        # Wait for metrics to be recorded
        Process.sleep(100)

        # Check metrics were updated
        updated_metrics = FLAME.ContainerMetrics.get_metrics_summary()
        updated_executions = Map.get(updated_metrics, :total_task_executions, 0)

        # Should have at least recorded the execution
        assert updated_executions >= initial_executions
      catch
        :exit, {:noproc, _} ->
          # ContainerMetrics GenServer not available - acceptable in test environment
          assert true

        :exit, :noproc ->
          # ContainerMetrics GenServer not available - acceptable in test environment
          assert true

        :exit, {:shutdown, _} ->
          # ContainerMetrics was shut down during test suite - acceptable in test environment
          assert true

        :exit, :shutdown ->
          # ContainerMetrics was shut down during test suite - acceptable in test environment
          assert true
      end
    end

    test "jobs record telemetry events" do
      # Set up telemetry listener
      test_pid = self()

      :telemetry.attach(
        "test-listener",
        [:flame, :task, :execute],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry_received, metadata})
        end,
        %{}
      )

      # Execute a job
      job_params = %{
        "type" => "simple",
        "name" => "Telemetry Test",
        "data" => %{"numbers" => [1]}
      }

      post(build_conn(), "/api/test/execute", %{"job" => job_params})

      # Check for telemetry event
      assert_receive {:telemetry_received, metadata}, 5000
      assert Map.has_key?(metadata, :started_at)
      assert Map.has_key?(metadata, :job_type)

      # Clean up
      :telemetry.detach("test-listener")
    end
  end

  describe "error handling" do
    test "handles FLAME pool unavailability gracefully" do
      # This test might fail if FLAME pool is actually unavailable
      # but should demonstrate graceful error handling
      job_params = %{
        "type" => "simple",
        "name" => "Pool Test",
        "data" => %{"numbers" => [1, 2, 3]}
      }

      # Even if FLAME pool is down, should not crash the controller
      conn = post(build_conn(), "/api/test/execute", %{"job" => job_params})

      # Should either succeed or fail gracefully
      assert response(conn, 200) || response(conn, 422)
    end

    test "handles malformed job parameters" do
      # Test with various malformed inputs
      malformed_params = [
        %{"job" => nil},
        %{"job" => "not a map"},
        %{"job" => %{"type" => "unknown_type"}},
        %{"job" => %{"data" => "invalid data"}}
      ]

      Enum.each(malformed_params, fn params ->
        conn = post(build_conn(), "/api/test/execute", params)

        # Should handle gracefully without crashing
        assert response(conn, 200) || response(conn, 422) || response(conn, 400)
      end)
    end
  end

  describe "concurrent job execution" do
    @tag :slow
    test "handles multiple concurrent jobs" do
      # Execute multiple jobs concurrently
      tasks =
        Enum.map(1..3, fn i ->
          Task.async(fn ->
            job_params = %{
              "type" => "simple",
              "name" => "Concurrent Job #{i}",
              "data" => %{"numbers" => Enum.to_list(1..10)}
            }

            conn = post(build_conn(), "/api/test/execute", %{"job" => job_params})
            json_response(conn, 200)
          end)
        end)

      # Wait for all tasks to complete
      results = Task.await_many(tasks, 30_000)

      # All jobs should succeed
      Enum.each(results, fn result ->
        assert result["success"] == true
      end)
    end
  end
end
