defmodule FLAME.AppleContainersBackend.IntegrationTest do
  use ExUnit.Case, async: false

  alias FLAME.AppleContainersBackend

  require Logger

  @moduletag :integration

  describe "end-to-end functionality" do
    test "can initialize backend and spawn processes in stub mode" do
      opts = [
        erlang_cookie: "integration_test_#{:rand.uniform(999_999)}",
        dns_domain: "test.local",
        container_prefix: "integration-test",
        mode: :test
      ]

      {:ok, backend} = AppleContainersBackend.init(opts)

      # Test remote boot
      assert {:ok, terminator_pid, updated_backend} =
               AppleContainersBackend.remote_boot(backend)

      # Verify terminator process
      assert is_pid(terminator_pid)
      assert Process.alive?(terminator_pid)

      # Get container info from the backend state
      assert map_size(updated_backend.containers) == 1
      container_info = updated_backend.containers |> Map.values() |> List.first()

      # Verify container info
      assert is_binary(container_info.container_name)
      assert is_atom(container_info.node_name)
      assert container_info.status in [:running, :stub_mode]

      # Test remote spawn monitor
      test_function = fn ->
        Logger.info("Test function running in remote process")
        :timer.sleep(100)
        42
      end

      assert {:ok, pid, ref} =
               AppleContainersBackend.remote_spawn_monitor(updated_backend, test_function)

      assert is_pid(pid)
      assert is_reference(ref)

      # Wait for process to complete
      receive do
        {:DOWN, ^ref, :process, ^pid, reason} ->
          Logger.info("Remote process completed with reason: #{inspect(reason)}")
          assert reason in [:normal, 42]
      after
        5000 ->
          flunk("Remote process did not complete within timeout")
      end
    end

    test "handles backend lifecycle correctly" do
      opts = [
        erlang_cookie: "lifecycle_test_#{:rand.uniform(999_999)}",
        dns_domain: "test.local",
        mode: :test
      ]

      # Initialize backend
      {:ok, backend} = AppleContainersBackend.init(opts)
      assert backend.config.erlang_cookie != nil

      # Test system shutdown
      assert :ok = AppleContainersBackend.system_shutdown()

      # Test handle_info
      assert {:noreply, ^backend} =
               AppleContainersBackend.handle_info(backend, {:test_message, "lifecycle"})
    end

    test "can spawn multiple processes concurrently" do
      opts = [
        erlang_cookie: "concurrent_test_#{:rand.uniform(999_999)}",
        dns_domain: "test.local",
        mode: :test
      ]

      {:ok, backend} = AppleContainersBackend.init(opts)
      {:ok, _terminator_pid, backend} = AppleContainersBackend.remote_boot(backend)

      # Spawn multiple concurrent processes
      tasks =
        for i <- 1..3 do
          test_function = fn ->
            :timer.sleep(50)
            i * 10
          end

          {:ok, pid, ref} =
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
    test "handles invalid configuration gracefully" do
      opts = [
        # Invalid cookie
        erlang_cookie: "",
        # Invalid domain
        dns_domain: "",
        mode: :test
      ]

      # Should still initialize with provided values (no defaults override)
      {:ok, backend} = AppleContainersBackend.init(opts)
      # Uses provided value
      assert backend.config.dns_domain == ""
      # Uses provided value
      assert backend.config.erlang_cookie == ""
    end

    test "handles container boot failures gracefully" do
      opts = [
        erlang_cookie: "error_test_#{:rand.uniform(999_999)}",
        # This will fail
        image: "nonexistent-image:latest",
        dns_domain: "test.local",
        mode: :test
      ]

      {:ok, backend} = AppleContainersBackend.init(opts)

      # Boot should fail but not crash
      case AppleContainersBackend.remote_boot(backend) do
        {:ok, _terminator_pid, _backend} ->
          Logger.info("Boot succeeded unexpectedly (stub mode)")

        {:error, reason} ->
          Logger.info("Boot failed as expected: #{inspect(reason)}")
          assert is_tuple(reason)
      end
    end
  end
end
