defmodule FLAME.AppleContainers.CLI do
  @moduledoc """
  Behaviour defining the interface for Apple Container CLI operations.

  All container CLI interactions go through this behaviour, allowing the real
  implementation to be swapped for a mock in tests.

  ## Configuration

  Set the adapter in your config:

      config :flame_apple_container_backend, :cli_adapter, FLAME.AppleContainers.CLI.System

  Or in tests:

      config :flame_apple_container_backend, :cli_adapter, FLAME.AppleContainers.CLI.Mock
  """

  @type cmd_result :: {output :: String.t(), exit_code :: non_neg_integer()}

  # DNS operations
  @callback list_dns_domains() :: cmd_result()

  # Container lifecycle
  @callback run_container(args :: [String.t()]) :: cmd_result()
  @callback stop_container(name :: String.t(), opts :: keyword()) :: cmd_result()
  @callback kill_container(name :: String.t()) :: cmd_result()

  # Container inspection
  @callback inspect_container(name :: String.t()) :: cmd_result()
  @callback list_containers(args :: [String.t()]) :: cmd_result()
  @callback get_container_stats(name :: String.t(), args :: [String.t()]) :: cmd_result()

  # Container execution
  @callback exec_in_container(name :: String.t(), command :: [String.t()]) :: cmd_result()

  # Image operations
  @callback list_images(args :: [String.t()]) :: cmd_result()
  @callback build_image(args :: [String.t()]) :: cmd_result()

  # Host info
  @callback hostname() :: cmd_result()

  @doc """
  Returns the configured CLI adapter module.

  Defaults to `FLAME.AppleContainers.CLI.System`.
  """
  def adapter do
    Application.get_env(
      :flame_apple_container_backend,
      :cli_adapter,
      FLAME.AppleContainers.CLI.System
    )
  end
end
