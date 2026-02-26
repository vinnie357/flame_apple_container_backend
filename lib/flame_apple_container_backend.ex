defmodule FlameAppleContainerBackend do
  @moduledoc """
  A FLAME backend for macOS Apple Containers.

  This package provides a backend implementation for the
  [FLAME](https://hex.pm/packages/flame) library that uses Apple's native
  container runtime on macOS. It enables elastic, on-demand compute by
  spinning up lightweight Apple Containers as FLAME worker nodes.

  ## Prerequisites

  - macOS 26 or later with Apple Container support
  - The `container` CLI tool installed and on your `PATH`

  ## Quick start

      # In your FLAME pool configuration:
      config :my_app, MyApp.FlamePool,
        backend: FLAME.AppleContainersBackend,
        min: 0,
        max: 10,
        max_concurrency: 5,
        idle_shutdown_after: 30_000
  """
end
