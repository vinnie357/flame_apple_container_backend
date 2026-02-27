defmodule FLAME.AppleContainers.CLI.SystemIntegrationTest do
  @moduledoc """
  Integration tests for the real CLI adapter.

  These tests require the `container` CLI (Apple Container 0.9.0+)
  installed on the host. They are excluded from CI by default.

  Run manually with:

      mix test --include integration
  """

  use ExUnit.Case

  @moduletag :integration

  alias FLAME.AppleContainers.CLI.System, as: CLISystem

  describe "dns operations" do
    test "list_dns_domains returns available domains" do
      {output, exit_code} = CLISystem.list_dns_domains()
      assert exit_code == 0
      assert is_binary(output)
      assert String.contains?(output, ".local")
    end
  end

  describe "hostname" do
    test "returns the host hostname" do
      {output, exit_code} = CLISystem.hostname()
      assert exit_code == 0
      assert String.trim(output) != ""
    end
  end

  describe "image operations" do
    test "list_images returns without error" do
      {_output, exit_code} = CLISystem.list_images()
      assert exit_code == 0
    end
  end

  describe "container operations" do
    test "list_containers returns without error" do
      {_output, exit_code} = CLISystem.list_containers()
      assert exit_code == 0
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
  end
end
