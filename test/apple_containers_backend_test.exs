defmodule FLAME.AppleContainersBackendTest do
  use ExUnit.Case, async: true

  alias FLAME.AppleContainers.CLI.Mock, as: CLIMock
  alias FLAME.AppleContainersBackend

  setup do
    CLIMock.set_responses(%{
      list_dns_domains: {"flame.local\ntest.local\n", 0},
      get_default_dns_domain: {"flame.local\n", 0},
      hostname: {"test-host.local\n", 0}
    })

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

    test "falls back to test.local when available and requested domain missing" do
      CLIMock.set_response(:list_dns_domains, {"prod.local\ntest.local\n", 0})

      opts = @base_opts ++ [dns_domain: "missing.local"]
      assert {:ok, backend} = AppleContainersBackend.init(opts)
      assert backend.dns_domain == "test.local"
    end

    test "falls back to default dns domain when no domains available" do
      CLIMock.set_responses(%{
        list_dns_domains: {"\n", 0},
        get_default_dns_domain: {"system-default.local\n", 0}
      })

      opts = @base_opts ++ [dns_domain: "missing.local"]
      assert {:ok, backend} = AppleContainersBackend.init(opts)
      assert backend.dns_domain == "system-default.local"
    end

    test "falls back to requested domain when no domains and default fails" do
      CLIMock.set_responses(%{
        list_dns_domains: {"\n", 0},
        get_default_dns_domain: {"", 1}
      })

      opts = @base_opts ++ [dns_domain: "last-resort.local"]
      assert {:ok, backend} = AppleContainersBackend.init(opts)
      assert backend.dns_domain == "last-resort.local"
    end

    test "falls back to requested domain when dns list fails" do
      CLIMock.set_response(:list_dns_domains, {"error: not available", 1})

      opts = @base_opts ++ [dns_domain: "flame.local"]
      assert {:ok, backend} = AppleContainersBackend.init(opts)
      assert backend.dns_domain == "flame.local"
    end

    test "initializes with clustering enabled" do
      opts = @base_opts ++ [enable_clustering: true, network_name: "my-net"]
      assert {:ok, backend} = AppleContainersBackend.init(opts)
      assert backend.enable_clustering == true
      assert backend.network_name == "my-net"
    end

    test "initializes with env as map" do
      opts = @base_opts ++ [env: %{"KEY" => "val"}]
      assert {:ok, backend} = AppleContainersBackend.init(opts)
      assert backend.env == %{"KEY" => "val"}
    end

    test "initializes with string env vars" do
      opts = @base_opts ++ [env: ["KEY=val", "OTHER=thing"]]
      assert {:ok, backend} = AppleContainersBackend.init(opts)
      assert backend.env == ["KEY=val", "OTHER=thing"]
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

    test "includes volume and network args when configured" do
      opts =
        @base_opts ++
          [
            volumes: ["/data:/app/data"],
            enable_clustering: true,
            network_name: "flame-net"
          ]

      {:ok, backend} = AppleContainersBackend.init(opts)
      parent_ref = backend.parent_ref
      test_pid = self()

      CLIMock.set_response(:run_container, fn ->
        spawn(fn ->
          send(test_pid, {parent_ref, {:remote_up, self()}})
          Process.sleep(:infinity)
        end)

        {"container-id\n", 0}
      end)

      assert {:ok, _pid, _state} = AppleContainersBackend.remote_boot(backend)
    end

    test "includes string env vars in container args" do
      opts = @base_opts ++ [env: ["EXTRA=value"]]
      {:ok, backend} = AppleContainersBackend.init(opts)
      parent_ref = backend.parent_ref
      test_pid = self()

      CLIMock.set_response(:run_container, fn ->
        spawn(fn ->
          send(test_pid, {parent_ref, {:remote_up, self()}})
          Process.sleep(:infinity)
        end)

        {"container-id\n", 0}
      end)

      assert {:ok, _pid, _state} = AppleContainersBackend.remote_boot(backend)
    end

    test "includes map env vars in container args" do
      opts = @base_opts ++ [env: %{"MAP_KEY" => "map_val"}]
      {:ok, backend} = AppleContainersBackend.init(opts)
      parent_ref = backend.parent_ref
      test_pid = self()

      CLIMock.set_response(:run_container, fn ->
        spawn(fn ->
          send(test_pid, {parent_ref, {:remote_up, self()}})
          Process.sleep(:infinity)
        end)

        {"container-id\n", 0}
      end)

      assert {:ok, _pid, _state} = AppleContainersBackend.remote_boot(backend)
    end

    test "logs when log option is set" do
      opts = @base_opts ++ [log: :info]
      {:ok, backend} = AppleContainersBackend.init(opts)
      parent_ref = backend.parent_ref
      test_pid = self()

      CLIMock.set_response(:run_container, fn ->
        spawn(fn ->
          send(test_pid, {parent_ref, {:remote_up, self()}})
          Process.sleep(:infinity)
        end)

        {"container-id\n", 0}
      end)

      assert {:ok, _pid, _state} = AppleContainersBackend.remote_boot(backend)
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

    test "exits on timeout and falls back to kill when stop fails" do
      {:ok, backend} = AppleContainersBackend.init(@base_opts ++ [boot_timeout: 100])

      pid =
        spawn(fn ->
          CLIMock.set_responses(%{
            run_container: {"container-id-123\n", 0},
            stop_container: {"error", 1},
            kill_container: {"", 0}
          })

          AppleContainersBackend.remote_boot(backend)
        end)

      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :timeout}, 500
    end

    test "exits on timeout when both stop and kill fail" do
      {:ok, backend} = AppleContainersBackend.init(@base_opts ++ [boot_timeout: 100])

      pid =
        spawn(fn ->
          CLIMock.set_responses(%{
            run_container: {"container-id-123\n", 0},
            stop_container: {"error", 1},
            kill_container: {"error", 1}
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

  describe "inspect/1" do
    test "renders struct with safe fields only" do
      {:ok, backend} = AppleContainersBackend.init(@base_opts)
      output = inspect(backend)

      assert output =~ "FLAME.AppleContainersBackend"
      assert output =~ "image:"
      assert output =~ "dns_domain:"
      # Sensitive fields should be excluded
      refute output =~ "encoded_parent:"
      refute output =~ "parent_ref:"
      refute output =~ "erlang_cookie:"
    end
  end

  describe "handle_info/2" do
    test "returns noreply with unchanged state" do
      {:ok, backend} = AppleContainersBackend.init(@base_opts)

      assert {:noreply, ^backend} =
               AppleContainersBackend.handle_info({:some_message, "data"}, backend)
    end

    test "logs message when log option is set" do
      {:ok, backend} = AppleContainersBackend.init(@base_opts ++ [log: :debug])

      assert {:noreply, ^backend} =
               AppleContainersBackend.handle_info({:some_message, "data"}, backend)
    end
  end
end
