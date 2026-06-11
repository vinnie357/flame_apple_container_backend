defmodule FLAME.AppleContainers.CLI.System do
  @moduledoc """
  Real CLI adapter that delegates to `System.cmd/3`.

  This is the default adapter used in production to interact with
  the Apple Container CLI (`container` command).
  """

  @behaviour FLAME.AppleContainers.CLI

  @impl true
  def list_dns_domains do
    System.cmd("container", ["system", "dns", "list"], stderr_to_stdout: true)
  end

  @impl true
  def run_container(args) do
    System.cmd("container", ["run" | args], stderr_to_stdout: true)
  end

  @impl true
  def stop_container(name, opts \\ []) do
    time = Keyword.get(opts, :time)
    args = if time, do: ["stop", name, "--time", to_string(time)], else: ["stop", name]
    System.cmd("container", args, stderr_to_stdout: true)
  end

  @impl true
  def kill_container(name) do
    System.cmd("container", ["kill", name], stderr_to_stdout: true)
  end

  @impl true
  def inspect_container(name) do
    System.cmd("container", ["inspect", name], stderr_to_stdout: true)
  end

  @impl true
  def list_containers(args \\ []) do
    System.cmd("container", ["list" | args], stderr_to_stdout: true)
  end

  @impl true
  def get_container_stats(name, args \\ []) do
    System.cmd("container", ["stats", name | args], stderr_to_stdout: true)
  end

  @impl true
  def exec_in_container(name, command) do
    System.cmd("container", ["exec", name | command], stderr_to_stdout: true)
  end

  @impl true
  def list_images(args \\ []) do
    System.cmd("container", ["image", "ls" | args], stderr_to_stdout: true)
  end

  @impl true
  def build_image(args) do
    System.cmd("container", ["build" | args], stderr_to_stdout: true)
  end

  @impl true
  def hostname do
    System.cmd("hostname", [])
  end
end
