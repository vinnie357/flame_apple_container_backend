defmodule FLAME.AppleContainers.CLI.SystemIntegrationTest do
  @moduledoc """
  Integration tests for the real CLI adapter against container CLI 1.0.0+.

  These tests require the `container` CLI (Apple Container 1.0.0+)
  installed on the host. They are excluded from CI by default.

  Run manually with:

      mix test --include integration
  """

  use ExUnit.Case

  @moduletag :integration

  alias FLAME.AppleContainers.CLI.System, as: CLISystem

  @test_image "alpine:latest"

  describe "version" do
    test "container CLI is 1.0.0+" do
      {output, 0} = System.cmd("container", ["--version"], stderr_to_stdout: true)
      assert output =~ ~r/container CLI version (\d+)\.(\d+)\.(\d+)/

      [_, major, minor, _patch] =
        Regex.run(~r/container CLI version (\d+)\.(\d+)\.(\d+)/, output)

      version = {String.to_integer(major), String.to_integer(minor)}
      assert version >= {1, 0}, "Expected container CLI >= 1.0.0, got #{output}"
    end
  end

  describe "dns operations" do
    test "list_dns_domains returns header and domains" do
      {output, exit_code} = CLISystem.list_dns_domains()
      assert exit_code == 0
      assert is_binary(output)

      lines =
        output
        |> String.trim()
        |> String.split("\n")

      assert hd(lines) == "DOMAIN"
      assert length(lines) >= 2, "Expected at least one domain after header"

      domains = tl(lines)
      assert Enum.all?(domains, &String.contains?(&1, ".local"))
    end
  end

  describe "hostname" do
    test "returns the host hostname" do
      {output, exit_code} = CLISystem.hostname()
      assert exit_code == 0
      hostname = String.trim(output)
      assert hostname != ""
      assert String.contains?(hostname, ".")
    end
  end

  describe "image operations" do
    test "list_images returns header and entries" do
      {output, exit_code} = CLISystem.list_images()
      assert exit_code == 0

      lines =
        output
        |> String.trim()
        |> String.split("\n")

      assert hd(lines) =~ "NAME"
      assert hd(lines) =~ "TAG"
      assert hd(lines) =~ "DIGEST"
    end
  end

  describe "container lifecycle" do
    test "run, inspect, exec, stats, stop, kill full cycle" do
      container_name = "integration-test-#{System.unique_integer([:positive])}"

      # Run
      {output, exit_code} =
        CLISystem.run_container([
          "--name",
          container_name,
          "--detach",
          "--rm",
          @test_image,
          "sleep",
          "120"
        ])

      assert exit_code == 0
      assert String.trim(output) == container_name

      try do
        # Inspect running
        {output, exit_code} = CLISystem.inspect_container(container_name)
        assert exit_code == 0
        assert {:ok, [container_info]} = Jason.decode(output)
        assert container_info["status"] == "running"

        # Exec
        {output, exit_code} = CLISystem.exec_in_container(container_name, ["echo", "hello"])
        assert exit_code == 0
        assert String.trim(output) == "hello"

        # Stats
        {output, exit_code} =
          CLISystem.get_container_stats(container_name, ["--no-stream"])

        assert exit_code == 0
        assert output =~ "Container ID"
        assert output =~ container_name

        # Stop
        {output, exit_code} = CLISystem.stop_container(container_name, time: 10)
        assert exit_code == 0
        assert String.trim(output) == container_name
      after
        # Ensure cleanup even if assertions fail
        CLISystem.kill_container(container_name)
      end
    end
  end

  describe "image build" do
    test "build_image --help describes the build subcommand" do
      {output, 0} = CLISystem.build_image(["--help"])
      assert output =~ "Build an image from a Dockerfile"
    end

    test "build_image builds an image from a trivial Dockerfile" do
      unique = System.unique_integer([:positive])
      dir = Path.join(System.tmp_dir(), "flame-it-build-#{unique}")
      tag = "flame-it-build-#{unique}:test"

      :ok = File.mkdir_p(dir)

      on_exit(fn ->
        {_output, _code} =
          System.cmd("container", ["image", "delete", tag], stderr_to_stdout: true)

        {:ok, _} = File.rm_rf(dir)
      end)

      dockerfile_path = Path.join(dir, "Dockerfile")
      :ok = File.write(dockerfile_path, "FROM alpine:latest\n")

      {_output, exit_code} = CLISystem.build_image(["-t", tag, dir])
      assert exit_code == 0
    end
  end

  describe "container operations (no running container needed)" do
    test "list_containers returns header" do
      {output, exit_code} = CLISystem.list_containers()
      assert exit_code == 0
      assert is_binary(output)
    end

    test "inspect_container returns empty array for nonexistent container" do
      {output, exit_code} =
        CLISystem.inspect_container("nonexistent-#{System.unique_integer([:positive])}")

      assert exit_code == 0
      assert String.trim(output) == "[]"
    end

    test "stop_container succeeds silently for nonexistent container" do
      {_output, exit_code} =
        CLISystem.stop_container("nonexistent-#{System.unique_integer([:positive])}")

      assert exit_code == 0
    end

    test "kill_container succeeds silently for nonexistent container" do
      {_output, exit_code} =
        CLISystem.kill_container("nonexistent-#{System.unique_integer([:positive])}")

      assert exit_code == 0
    end

    test "exec_in_container returns error for nonexistent container" do
      {output, exit_code} =
        CLISystem.exec_in_container(
          "nonexistent-#{System.unique_integer([:positive])}",
          ["echo", "test"]
        )

      assert exit_code == 1
      assert output =~ "notFound"
    end

    test "get_container_stats returns error for nonexistent container" do
      {output, exit_code} =
        CLISystem.get_container_stats(
          "nonexistent-#{System.unique_integer([:positive])}",
          ["--no-stream"]
        )

      assert exit_code == 1
      assert output =~ "notFound"
    end
  end
end
