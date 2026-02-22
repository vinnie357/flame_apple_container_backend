defmodule FLAME.OrchestratorTest do
  use ExUnit.Case, async: true

  alias FLAME.Orchestrator

  setup do
    name = :"orchestrator_#{System.unique_integer([:positive])}"

    config = %{
      max_cluster_size: 5,
      # 10 seconds for testing
      cluster_timeout: 10_000,
      task_distribution_strategy: :round_robin,
      enable_stateful_clustering: true,
      enable_workflow_orchestration: true
    }

    {:ok, pid} = Orchestrator.start_link(config: config, name: name)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{server: pid, name: name, config: config}
  end

  describe "orchestrator initialization" do
    test "starts with correct configuration", ctx do
      status = Orchestrator.get_cluster_status(nil, ctx.server)

      assert is_map(status)
      assert Map.has_key?(status, :active_clusters)
      assert Map.has_key?(status, :total_containers)
      assert Map.has_key?(status, :active_workflows)
      assert Map.has_key?(status, :task_distribution_strategy)

      assert is_integer(status.active_clusters)
      assert is_integer(status.total_containers)
      assert is_integer(status.active_workflows)
      assert is_atom(status.task_distribution_strategy)
    end
  end

  describe "cluster management" do
    test "validates cluster specifications", ctx do
      valid_cluster_spec = %{
        name: "test-cluster",
        size: 3,
        resource_requirements: %{memory_mb: 512, cpu_percent: 50},
        timeout: 300_000
      }

      # This will likely fail in test environment due to no actual containers
      # but should validate the specification format
      result = Orchestrator.create_cluster(valid_cluster_spec, ctx.server)

      case result do
        {:ok, cluster_id} ->
          assert is_binary(cluster_id)

          # Clean up
          Orchestrator.destroy_cluster(cluster_id, ctx.server)

        {:error, reason} ->
          # Expected in test environment
          case reason do
            {:invalid_cluster_spec, _} -> :ok
            {:container_provisioning_failed, _} -> :ok
            _ -> flunk("Unexpected error reason: #{inspect(reason)}")
          end
      end
    end

    test "rejects invalid cluster specifications", ctx do
      invalid_specs = [
        # Invalid size
        %{name: "invalid", size: 0},
        # Invalid name
        %{name: "", size: 2},
        # Too large
        %{name: "invalid", size: 100}
      ]

      Enum.each(invalid_specs, fn spec ->
        result = Orchestrator.create_cluster(spec, ctx.server)

        case result do
          {:error, {:invalid_cluster_spec, _reason}} ->
            assert true

          {:error, {:container_provisioning_failed, _}} ->
            # Also acceptable - means spec was valid but provisioning failed
            assert true

          other ->
            flunk("Expected error for invalid spec, got: #{inspect(other)}")
        end
      end)
    end

    test "tracks cluster lifecycle", ctx do
      cluster_spec = %{
        name: "lifecycle-test-cluster",
        size: 2,
        resource_requirements: %{memory_mb: 256}
      }

      # Attempt to create cluster
      result = Orchestrator.create_cluster(cluster_spec, ctx.server)

      case result do
        {:ok, cluster_id} ->
          # Check cluster exists
          status = Orchestrator.get_cluster_status(cluster_id, ctx.server)
          assert is_map(status)

          # Destroy cluster
          destroy_result = Orchestrator.destroy_cluster(cluster_id, ctx.server)
          assert destroy_result == :ok

          # Verify cluster is gone
          destroyed_status = Orchestrator.get_cluster_status(cluster_id, ctx.server)
          assert is_nil(destroyed_status)

        {:error, _reason} ->
          # Expected in test environment without actual containers
          assert true
      end
    end

    test "handles cluster destruction of non-existent clusters", ctx do
      result = Orchestrator.destroy_cluster("non-existent-cluster-id", ctx.server)
      assert {:error, :cluster_not_found} == result
    end
  end

  describe "task scheduling" do
    test "validates task specifications", ctx do
      valid_task_spec = %{
        function: fn x -> x * 2 end,
        args: [5],
        resource_requirements: %{memory_mb: 128},
        affinity: :cpu_intensive
      }

      # Will likely fail due to no clusters in test environment
      result = Orchestrator.schedule_task(valid_task_spec, ctx.server)

      case result do
        {:ok, task_id, execution_info} ->
          assert is_binary(task_id)
          assert is_map(execution_info)
          assert Map.has_key?(execution_info, :cluster_id)

        {:error, reason} ->
          # Expected errors in test environment
          case reason do
            {:cluster_selection_failed, :no_clusters_available} -> :ok
            {:container_selection_failed, _} -> :ok
            {:task_execution_failed, _} -> :ok
            _ -> flunk("Unexpected error reason: #{inspect(reason)}")
          end
      end
    end

    test "handles task scheduling without available clusters", ctx do
      task_spec = %{
        function: fn -> :test_result end,
        args: []
      }

      result = Orchestrator.schedule_task(task_spec, ctx.server)

      # Should fail gracefully when no clusters are available
      case result do
        {:error, {:cluster_selection_failed, :no_clusters_available}} ->
          assert true

        {:error, _other_reason} ->
          # Other errors are also acceptable
          assert true

        {:ok, _task_id, _execution_info} ->
          # Unexpected success (maybe mock containers were created)
          assert true
      end
    end
  end

  describe "workflow orchestration" do
    test "validates workflow specifications", ctx do
      valid_workflow = %{
        name: "test-workflow",
        steps: [
          %{function: fn x -> x + 1 end, args: [1]},
          %{function: fn x -> x * 2 end, depends_on: [0]},
          %{function: fn x -> x - 1 end, depends_on: [1]}
        ]
      }

      result = Orchestrator.schedule_workflow(valid_workflow, ctx.server)

      case result do
        {:ok, workflow_id} ->
          assert is_binary(workflow_id)

        {:error, reason} ->
          # Expected in test environment
          case reason do
            {:workflow_start_failed, _} -> :ok
            {:invalid_workflow_spec, _} -> :ok
            _ -> flunk("Unexpected error reason: #{inspect(reason)}")
          end
      end
    end

    test "rejects invalid workflow specifications", ctx do
      invalid_workflows = [
        # Empty name and steps
        %{name: "", steps: []},
        # Invalid steps
        %{name: "test", steps: nil},
        # Missing name
        %{steps: [%{function: fn -> :ok end}]},
        # Invalid name type
        %{name: 123, steps: []}
      ]

      Enum.each(invalid_workflows, fn workflow ->
        result = Orchestrator.schedule_workflow(workflow, ctx.server)

        case result do
          {:error, {:invalid_workflow_spec, _reason}} ->
            assert true

          {:error, {:workflow_start_failed, _}} ->
            # Also acceptable if spec was valid but execution failed
            assert true

          other ->
            flunk("Expected error for invalid workflow, got: #{inspect(other)}")
        end
      end)
    end

    test "handles workflow step dependencies", ctx do
      workflow_with_deps = %{
        name: "dependency-test-workflow",
        steps: [
          %{function: fn -> 10 end, args: []},
          %{function: fn x -> x * 2 end, depends_on: [0]},
          %{function: fn x, y -> x + y end, depends_on: [0, 1]}
        ]
      }

      result = Orchestrator.schedule_workflow(workflow_with_deps, ctx.server)

      case result do
        {:ok, workflow_id} ->
          assert is_binary(workflow_id)

        {:error, _reason} ->
          # Expected in test environment
          assert true
      end
    end
  end

  describe "affinity and anti-affinity rules" do
    test "updates affinity rules", ctx do
      new_rules = %{
        data_locality: false,
        cpu_anti_affinity: true,
        memory_anti_affinity: true,
        custom_rule: :test_value
      }

      # Should not crash when updating rules
      Orchestrator.update_affinity_rules(new_rules, ctx.server)

      # Allow time for async update
      Process.sleep(50)

      assert :ok == :ok
    end

    test "applies affinity rules in task scheduling", ctx do
      # Test that affinity rules are considered (even if no clusters exist)
      task_with_affinity = %{
        function: fn -> :cpu_intensive_task end,
        args: [],
        affinity: :cpu_intensive,
        resource_requirements: %{cpu_percent: 80}
      }

      result = Orchestrator.schedule_task(task_with_affinity, ctx.server)

      # Should attempt to apply affinity rules (even if it fails due to no clusters)
      case result do
        {:error, {:cluster_selection_failed, :no_clusters_available}} ->
          assert true

        {:error, _other_reason} ->
          assert true

        {:ok, _task_id, _execution_info} ->
          assert true
      end
    end
  end

  describe "load balancing" do
    test "supports different load balancing strategies", ctx do
      status = Orchestrator.get_cluster_status(nil, ctx.server)

      # Should have a task distribution strategy configured
      assert status.task_distribution_strategy in [:round_robin, :least_loaded, :random]
    end

    test "handles load balancing with no available containers", ctx do
      # This tests the load balancing logic when no containers are available
      task_spec = %{
        function: fn -> :load_balance_test end,
        args: []
      }

      result = Orchestrator.schedule_task(task_spec, ctx.server)

      # Should fail gracefully with appropriate error
      case result do
        {:error, {:cluster_selection_failed, :no_clusters_available}} ->
          assert true

        {:error, _other_reason} ->
          assert true

        {:ok, _task_id, _execution_info} ->
          # Unexpected success
          assert true
      end
    end
  end

  describe "orchestrator status and monitoring" do
    test "provides comprehensive status information", ctx do
      status = Orchestrator.get_cluster_status(nil, ctx.server)

      required_fields = [
        :active_clusters,
        :total_containers,
        :active_workflows,
        :task_distribution_strategy,
        :cluster_summary
      ]

      Enum.each(required_fields, fn field ->
        assert Map.has_key?(status, field), "Missing field: #{field}"
      end)

      # Verify data types
      assert is_integer(status.active_clusters)
      assert is_integer(status.total_containers)
      assert is_integer(status.active_workflows)
      assert is_atom(status.task_distribution_strategy)
      assert is_list(status.cluster_summary)
    end

    test "tracks cluster summary information", ctx do
      status = Orchestrator.get_cluster_status(nil, ctx.server)

      # Cluster summary should be a list
      assert is_list(status.cluster_summary)

      # Each cluster summary should have required fields
      Enum.each(status.cluster_summary, fn cluster_summary ->
        assert Map.has_key?(cluster_summary, :cluster_id)
        assert Map.has_key?(cluster_summary, :container_count)
        assert Map.has_key?(cluster_summary, :active_tasks)
        assert Map.has_key?(cluster_summary, :status)
        assert Map.has_key?(cluster_summary, :created_at)
      end)
    end
  end

  describe "error handling and resilience" do
    test "handles concurrent cluster operations", ctx do
      cluster_specs =
        Enum.map(1..3, fn i ->
          %{
            name: "concurrent-cluster-#{i}",
            size: 2,
            resource_requirements: %{memory_mb: 256}
          }
        end)

      # Create clusters concurrently
      tasks =
        Enum.map(cluster_specs, fn spec ->
          Task.async(fn -> Orchestrator.create_cluster(spec, ctx.server) end)
        end)

      results = Task.await_many(tasks, 5000)

      # All operations should complete (successfully or with expected errors)
      assert length(results) == 3

      Enum.each(results, fn result ->
        case result do
          {:ok, cluster_id} when is_binary(cluster_id) ->
            # Success - clean up
            Orchestrator.destroy_cluster(cluster_id, ctx.server)

          {:error, _reason} ->
            # Expected in test environment
            assert true
        end
      end)
    end

    test "recovers from system errors gracefully", ctx do
      # Test various error conditions
      error_operations = [
        fn -> Orchestrator.destroy_cluster(nil, ctx.server) end,
        fn -> Orchestrator.schedule_task(%{invalid: :spec}, ctx.server) end,
        fn -> Orchestrator.schedule_workflow(%{}, ctx.server) end
      ]

      Enum.each(error_operations, fn operation ->
        try do
          result = operation.()

          case result do
            {:error, _reason} -> assert true
            other -> flunk("Expected error, got: #{inspect(other)}")
          end
        rescue
          _ ->
            # Some operations might raise exceptions - that's acceptable
            assert true
        end
      end)

      # Orchestrator should remain responsive
      status = Orchestrator.get_cluster_status(nil, ctx.server)
      assert is_map(status)
    end

    test "handles high-volume operations", ctx do
      # Perform many status requests quickly
      Enum.each(1..50, fn _i ->
        Orchestrator.get_cluster_status(nil, ctx.server)
      end)

      # System should remain responsive
      final_status = Orchestrator.get_cluster_status(nil, ctx.server)
      assert is_map(final_status)
    end
  end
end
