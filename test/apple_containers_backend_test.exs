defmodule FLAME.AppleContainersBackendTest do
  use ExUnit.Case, async: true

  alias FLAME.AppleContainers.CLI.Mock, as: CLIMock
  alias FLAME.AppleContainersBackend

  setup do
    original = Application.get_env(:flame_apple_container_backend, :cli_adapter)
    Application.put_env(:flame_apple_container_backend, :cli_adapter, CLIMock)

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

  @base_opts [
    erlang_cookie: "test_cookie",
    image: "test-image:latest"
  ]

  describe "init/1" do
    test "initializes with default configuration" do
      assert {:ok, backend} = AppleContainersBackend.init(@base_opts)
      assert backend.image == "test-image:latest"
      assert backend.dns_domain == "flame.local"
      assert backend.erlang_cookie == "test_cookie"
      assert is_reference(backend.parent_ref)
      assert is_binary(backend.encoded_parent)
      assert is_binary(backend.runner_node_base)
    end

    test "uses default values when not provided" do
      assert {:ok, backend} = AppleContainersBackend.init([])
      assert backend.image == "flame-worker:latest"
      assert backend.container_prefix == "flame-worker"
      assert backend.boot_timeout == 30_000
      assert backend.volumes == []
      assert backend.env == []
    end

    test "initializes with volume mounts" do
      opts =
        @base_opts ++
          [volumes: ["/host/.claude:/home/elixir/.claude:ro", "/data:/app/data"]]

      assert {:ok, backend} = AppleContainersBackend.init(opts)

      assert backend.volumes == [
               "/host/.claude:/home/elixir/.claude:ro",
               "/data:/app/data"
             ]
    end

    test "initializes with extra env vars" do
      opts = @base_opts ++ [env: [{"API_KEY", "secret123"}]]
      assert {:ok, backend} = AppleContainersBackend.init(opts)
      assert backend.env == [{"API_KEY", "secret123"}]
    end

    test "falls back when requested domain not available" do
      CLIMock.set_response(:list_dns_domains, {"other.local\n", 0})

      opts = @base_opts ++ [dns_domain: "missing.local"]
      assert {:ok, backend} = AppleContainersBackend.init(opts)
      assert backend.dns_domain == "other.local"
    end

    test "falls back to requested domain when dns list fails" do
      CLIMock.set_response(:list_dns_domains, {"error: not available", 1})

      opts = @base_opts ++ [dns_domain: "flame.local"]
      assert {:ok, backend} = AppleContainersBackend.init(opts)
      assert backend.dns_domain == "flame.local"
    end

    test "encoded_parent contains FLAME.Parent data" do
      assert {:ok, backend} = AppleContainersBackend.init(@base_opts)
      decoded = backend.encoded_parent |> Base.decode64!() |> :erlang.binary_to_term()
      assert decoded.backend == AppleContainersBackend
      assert decoded.node_base == backend.runner_node_base
      assert decoded.host_env == "FLAME_HOST"
      assert decoded.pid == self()
      assert decoded.ref == backend.parent_ref
    end
  end

  describe "remote_boot/1" do
    test "starts container and waits for terminator callback" do
      {:ok, backend} = AppleContainersBackend.init(@base_opts)
      parent_ref = backend.parent_ref
      test_pid = self()

      CLIMock.set_response(:run_container, fn ->
        # Simulate remote Terminator connecting back
        spawn(fn ->
          send(test_pid, {parent_ref, {:remote_up, self()}})
          Process.sleep(:infinity)
        end)

        {"container-id-123\n", 0}
      end)

      assert {:ok, terminator_pid, new_state} = AppleContainersBackend.remote_boot(backend)
      assert is_pid(terminator_pid)
      assert new_state.remote_terminator_pid == terminator_pid
      assert new_state.runner_node_name == node(terminator_pid)
    end

    test "returns error when container fails to start" do
      {:ok, backend} = AppleContainersBackend.init(@base_opts)

      CLIMock.set_response(:run_container, {"image not found\n", 125})

      assert {:error, {:container_start_failed, 125, _}} =
               AppleContainersBackend.remote_boot(backend)
    end

    test "exits on timeout when terminator never connects" do
      {:ok, backend} = AppleContainersBackend.init(@base_opts ++ [boot_timeout: 100])

      # remote_boot will exit(:timeout) when no {:remote_up, _} arrives.
      # Must set up mocks inside spawned process since CLIMock uses process dictionary.
      pid =
        spawn(fn ->
          CLIMock.set_responses(%{
            run_container: {"container-id-123\n", 0},
            stop_container: {"", 0}
          })

          AppleContainersBackend.remote_boot(backend)
        end)

      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :timeout}, 500
    end
  end

  describe "remote_spawn_monitor/2" do
    test "spawns function locally when runner is on same node" do
      {:ok, backend} = AppleContainersBackend.init(@base_opts)
      backend = %{backend | runner_node_name: node()}

      func = fn -> 2 + 2 end
      assert {:ok, {pid, ref}} = AppleContainersBackend.remote_spawn_monitor(backend, func)
      assert is_pid(pid)
      assert is_reference(ref)
    end

    test "spawns MFA locally when runner is on same node" do
      {:ok, backend} = AppleContainersBackend.init(@base_opts)
      backend = %{backend | runner_node_name: node()}

      assert {:ok, {pid, ref}} =
               AppleContainersBackend.remote_spawn_monitor(backend, {Kernel, :+, [1, 2]})

      assert is_pid(pid)
      assert is_reference(ref)
    end

    test "raises on invalid term" do
      {:ok, backend} = AppleContainersBackend.init(@base_opts)
      backend = %{backend | runner_node_name: node()}

      assert_raise ArgumentError, ~r/expected a null arity function/, fn ->
        AppleContainersBackend.remote_spawn_monitor(backend, :not_a_function)
      end
    end
  end

  describe "handle_info/2" do
    test "returns noreply with unchanged state" do
      {:ok, backend} = AppleContainersBackend.init(@base_opts)

      assert {:noreply, ^backend} =
               AppleContainersBackend.handle_info({:some_message, "data"}, backend)
    end
  end
end
