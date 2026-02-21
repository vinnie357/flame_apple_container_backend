defmodule FlameAppleContainerBackend do
  @moduledoc """
  A FLAME backend for macOS Apple Containers.

  This package provides a backend implementation for the
  [FLAME](https://hex.pm/packages/flame) library that uses Apple's native
  container runtime on macOS. It enables elastic, on-demand compute by
  spinning up lightweight Apple Containers as FLAME worker nodes.

  ## Features

  - **Container lifecycle management** — start, stop, and monitor Apple
    Containers via the `container` CLI
  - **Security** — RBAC, policy engine, compliance checks, and audit logging
  - **Monitoring** — container health checks, metrics collection, circuit
    breaking, and alerting
  - **Orchestration** — task scheduling, cluster management, and image
    lifecycle
  - **Web dashboard** — optional Phoenix LiveView UI for real-time visibility

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

  ## Configuration

  All features are opt-in via environment variables prefixed with `FLAME_`:

  | Variable | Default | Description |
  |----------|---------|-------------|
  | `FLAME_ENABLE_METRICS` | `"false"` | Enable metrics collection |
  | `FLAME_ENABLE_SECURITY` | `"false"` | Enable security subsystems |
  | `FLAME_ENABLE_WEB_INTERFACE` | `"false"` | Enable Phoenix dashboard |
  | `FLAME_ENABLE_ORCHESTRATION` | `"false"` | Enable task orchestration |
  | `FLAME_MINIMAL_MODE` | `"false"` | Start only core processes |

  See `FlameAppleContainerBackend.Application` for the full list.
  """
end
