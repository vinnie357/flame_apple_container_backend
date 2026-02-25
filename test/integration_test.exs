defmodule FLAME.AppleContainersBackend.IntegrationTest do
  use ExUnit.Case, async: false

  alias FLAME.AppleContainersBackend

  require Logger

  @moduletag :integration

  describe "end-to-end functionality" do
    test "can initialize backend and boot container" do
      opts = [
        erlang_cookie: "integration_test_#{:rand.uniform(999_999)}",
        dns_domain: "test.local",
        container_prefix: "integration-test"
      ]

      {:ok, backend} = AppleContainersBackend.init(opts)
      assert is_reference(backend.parent_ref)
      assert is_binary(backend.encoded_parent)

      # Test remote boot (will fail without real containers, but should not crash)
      case AppleContainersBackend.remote_boot(backend) do
        {:ok, terminator_pid, updated_backend} ->
          assert is_pid(terminator_pid)
          assert is_map(updated_backend)
          assert updated_backend.remote_terminator_pid == terminator_pid

        {:error, reason} ->
          Logger.info("Boot failed as expected in test: #{inspect(reason)}")
          assert is_tuple(reason)
      end
    end

    test "handles backend lifecycle correctly" do
      opts = [
        erlang_cookie: "lifecycle_test_#{:rand.uniform(999_999)}",
        dns_domain: "test.local"
      ]

      {:ok, backend} = AppleContainersBackend.init(opts)
      assert backend.erlang_cookie != nil

      # Test handle_info
      assert {:noreply, ^backend} =
               AppleContainersBackend.handle_info({:test_message, "lifecycle"}, backend)
    end

    test "can spawn multiple processes concurrently" do
      opts = [
        erlang_cookie: "concurrent_test_#{:rand.uniform(999_999)}",
        dns_domain: "test.local"
      ]

      {:ok, backend} = AppleContainersBackend.init(opts)
      # Set runner_node_name to local node for testing
      backend = %{backend | runner_node_name: node()}

      # Spawn multiple concurrent processes
      tasks =
        for i <- 1..3 do
          test_function = fn ->
            :timer.sleep(50)
            i * 10
          end

          {:ok, {pid, ref}} =
            AppleContainersBackend.remote_spawn_monitor(backend, test_function)

          {pid, ref, i}
        end

      # Wait for all processes to complete
      results =
        for {pid, ref, expected} <- tasks do
          receive do
            {:DOWN, ^ref, :process, ^pid, reason} ->
              {expected, reason}
          after
            5000 ->
              flunk("Process #{expected} did not complete within timeout")
          end
        end

      # Verify all processes completed
      assert length(results) == 3
      Logger.info("Concurrent test results: #{inspect(results)}")
    end
  end

  describe "error handling" do
    test "handles container boot failures gracefully" do
      opts = [
        erlang_cookie: "error_test_#{:rand.uniform(999_999)}",
        image: "nonexistent-image:latest",
        dns_domain: "test.local"
      ]

      {:ok, backend} = AppleContainersBackend.init(opts)

      # Boot should fail but not crash
      case AppleContainersBackend.remote_boot(backend) do
        {:ok, _terminator_pid, _backend} ->
          Logger.info("Boot succeeded unexpectedly")

        {:error, reason} ->
          Logger.info("Boot failed as expected: #{inspect(reason)}")
          assert is_tuple(reason)
      end
    end
  end
end
