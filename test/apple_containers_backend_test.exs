defmodule FLAME.AppleContainersBackendTest do
  use ExUnit.Case, async: true

  alias FLAME.AppleContainers.CLI.Mock, as: CLIMock
  alias FLAME.AppleContainersBackend

  setup do
    # Configure mock CLI adapter for this test process
    original = Application.get_env(:flame_apple_container_backend, :cli_adapter)
    Application.put_env(:flame_apple_container_backend, :cli_adapter, CLIMock)

    # Set default DNS mock responses
    CLIMock.set_responses(%{
      list_dns_domains: {"flame.local\ntest.local\n", 0},
      get_default_dns_domain: {"flame.local\n", 0},
      hostname: {"test-host.local\n", 0}
    })

    on_exit(fn ->
      if original do
        Application.put_env(:flame_apple_container_backend, :cli_adapter, original)
      else
        Application.delete_env(:flame_apple_container_backend, :cli_adapter)
      end
    end)

    :ok
  end

  describe "backend initialization" do
    test "initializes with default configuration" do
      opts = [
        erlang_cookie: "test_cookie",
        image: "test-image:latest"
      ]

      assert {:ok, backend} = AppleContainersBackend.init(opts)
      assert backend.config.image == "test-image:latest"
      assert backend.config.dns_domain == "flame.local"
      assert backend.config.erlang_cookie == "test_cookie"
    end

    test "uses default values when not provided" do
      opts = []

      assert {:ok, backend} = AppleContainersBackend.init(opts)
      assert backend.config.image == "flame-worker:latest"
      assert backend.config.dns_domain == "flame.local"
      assert backend.config.container_prefix == "flame-worker"
      assert backend.config.erlang_cookie == "test_cookie"
      assert backend.config.volumes == []
    end

    test "initializes with volume mounts" do
      opts = [
        erlang_cookie: "test_cookie",
        image: "test-image:latest",
        volumes: ["/host/.claude:/home/elixir/.claude:ro", "/data:/app/data"]
      ]

      assert {:ok, backend} = AppleContainersBackend.init(opts)

      assert backend.config.volumes == [
               "/host/.claude:/home/elixir/.claude:ro",
               "/data:/app/data"
             ]

      assert backend.volumes == ["/host/.claude:/home/elixir/.claude:ro", "/data:/app/data"]
    end

    test "falls back when requested domain not available" do
      CLIMock.set_response(:list_dns_domains, {"other.local\n", 0})

      opts = [dns_domain: "missing.local"]

      assert {:ok, backend} = AppleContainersBackend.init(opts)
      # Should fall back to first available domain
      assert backend.config.dns_domain == "other.local"
    end

    test "falls back to default domain when dns list fails" do
      CLIMock.set_response(:list_dns_domains, {"error: not available", 1})
      CLIMock.set_response(:get_default_dns_domain, {"fallback.local\n", 0})

      opts = [dns_domain: "flame.local"]

      assert {:ok, backend} = AppleContainersBackend.init(opts)
      # Should use requested domain as fallback when list fails
      assert backend.config.dns_domain == "flame.local"
    end
  end

  describe "container lifecycle" do
    test "provisions container in test mode" do
      # Test mode executes functions locally, no container provisioning
      opts = [mode: :test, dns_domain: "test.local"]

      {:ok, backend} = AppleContainersBackend.init(opts)

      # remote_boot in non-test mode provisions a real container;
      # in test mode it falls through to direct provisioning which calls CLI.
      # Set mock responses for the provisioning path.
      # Mock the full container provisioning flow:
      # 1. inspect (check exists) -> not found is fine, verify_running -> success
      # 2. run -> success
      # 3. inspect (verify running) -> success
      # 4. exec (readiness check) -> success
      # Since mock returns same response per callback, use a counter for inspect
      call_count = :counters.new(1, [:atomics])

      CLIMock.set_responses(%{
        inspect_container: fn ->
          count = :counters.get(call_count, 1)
          :counters.add(call_count, 1, 1)

          if count == 0 do
            # First call: check_container_exists -> not found
            {"", 1}
          else
            # Subsequent calls: verify_container_running -> running
            {"{\"State\": \"running\"}", 0}
          end
        end,
        run_container: {"container-id-123\n", 0},
        exec_in_container: {"Elixir 1.19.5\n", 0}
      })

      assert {:ok, terminator_pid, updated_backend} =
               AppleContainersBackend.remote_boot(backend)

      assert is_pid(terminator_pid)
      assert Process.alive?(terminator_pid)

      assert map_size(updated_backend.containers) == 1
      container_info = updated_backend.containers |> Map.values() |> List.first()

      assert is_binary(container_info.container_name)
      assert is_atom(container_info.node_name)
      assert container_info.status == :running
      assert is_integer(container_info.started_at)
    end
  end

  describe "task execution" do
    test "spawns processes in test mode" do
      {:ok, backend} = AppleContainersBackend.init(mode: :test, dns_domain: "test.local")

      test_function = fn -> 2 + 2 end

      assert {:ok, pid, ref} =
               AppleContainersBackend.remote_spawn_monitor(backend, test_function)

      assert is_pid(pid)
      assert is_reference(ref)
    end
  end

  describe "system operations" do
    test "handles system shutdown" do
      assert :ok = AppleContainersBackend.system_shutdown()
    end

    test "handles info messages" do
      {:ok, backend} = AppleContainersBackend.init(mode: :test, dns_domain: "test.local")

      assert {:noreply, ^backend} =
               AppleContainersBackend.handle_info(backend, {:test_message, "hello"})
    end
  end
end
