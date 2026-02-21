defmodule FLAME.AppleContainersBackendTest do
  use ExUnit.Case, async: false

  alias FLAME.AppleContainersBackend

  describe "backend initialization" do
    test "initializes with default configuration" do
      opts = [
        erlang_cookie: "test_cookie",
        image: "test-image:latest"
      ]

      assert {:ok, backend} = AppleContainersBackend.init(opts)
      assert backend.config.image == "test-image:latest"
      # Backend falls back to test.local when flame.local is not available
      assert backend.config.dns_domain in ["flame.local", "test.local"]
      assert backend.config.erlang_cookie == "test_cookie"
    end

    test "uses default values when not provided" do
      opts = []

      assert {:ok, backend} = AppleContainersBackend.init(opts)
      assert backend.config.image == "flame-worker:latest"
      # Backend falls back to test.local when flame.local is not available
      assert backend.config.dns_domain in ["flame.local", "test.local"]
      assert backend.config.container_prefix == "flame-worker"
      assert backend.config.erlang_cookie == "test_cookie"
    end
  end

  describe "container lifecycle" do
    test "provisions container info in stub mode" do
      {:ok, backend} = AppleContainersBackend.init(mode: :test)

      assert {:ok, terminator_pid, updated_backend} =
               AppleContainersBackend.remote_boot(backend)

      assert is_pid(terminator_pid)
      assert Process.alive?(terminator_pid)

      # Get container info from the backend state
      assert map_size(updated_backend.containers) == 1
      container_info = updated_backend.containers |> Map.values() |> List.first()

      assert is_binary(container_info.container_name)
      assert is_atom(container_info.node_name)
      assert container_info.status == :running
      assert is_integer(container_info.started_at)

      # Verify container is tracked in backend
      assert Map.has_key?(updated_backend.containers, container_info.container_name)
    end
  end

  describe "task execution" do
    test "spawns processes in stub mode" do
      {:ok, backend} = AppleContainersBackend.init(mode: :test)

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
      {:ok, backend} = AppleContainersBackend.init(mode: :test)

      assert {:noreply, ^backend} =
               AppleContainersBackend.handle_info(backend, {:test_message, "hello"})
    end
  end
end
