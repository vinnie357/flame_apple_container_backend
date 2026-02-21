# FlameAppleContainerBackend

[![Hex.pm](https://img.shields.io/hexpm/v/flame_apple_container_backend.svg)](https://hex.pm/packages/flame_apple_container_backend)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/flame_apple_container_backend)

A [FLAME](https://hex.pm/packages/flame) backend that runs workers inside
macOS Apple Containers using the `container` CLI.

FLAME lets you elastically scale Elixir workloads by spawning short-lived
worker nodes on demand. This backend provisions those workers as lightweight
Apple Containers on macOS, giving you fast, isolated compute without leaving
your Mac.

## Prerequisites

- macOS 26 or later with Apple Container support
- The `container` CLI tool on your `PATH`
- Elixir ~> 1.15

## Installation

Add the dependency to your `mix.exs`:

```elixir
def deps do
  [
    {:flame_apple_container_backend, "~> 0.1.0"},
    {:flame, "~> 0.5.2"}
  ]
end
```

## Usage

Configure a FLAME pool to use the Apple Containers backend:

```elixir
# config/config.exs
config :my_app, MyApp.FlamePool,
  backend: FLAME.AppleContainersBackend,
  min: 0,
  max: 10,
  max_concurrency: 5,
  idle_shutdown_after: 30_000
```

Then call into the pool from your application:

```elixir
FLAME.call(MyApp.FlamePool, fn ->
  # This runs inside an Apple Container
  heavy_computation()
end)
```

## Features

All features are optional and controlled via environment variables prefixed
with `FLAME_`:

| Feature | Env Variable | Modules |
|---------|-------------|---------|
| Container management | *(always on)* | `FLAME.AppleContainers.Manager`, `Pool`, `Monitor` |
| Security (RBAC, audit, policies) | `FLAME_ENABLE_SECURITY` | `FLAME.Security.RBAC`, `PolicyEngine`, `ComplianceManager`, `AuditLogger` |
| Metrics & health | `FLAME_ENABLE_METRICS` | `FLAME.ContainerMetrics`, `ContainerHealth` |
| Alerting | `FLAME_ENABLE_METRICS` | `FLAME.AlertManager` |
| Orchestration | `FLAME_ENABLE_ORCHESTRATION` | `FLAME.Orchestrator`, `ClusterManager`, `ImageManager` |
| Web dashboard | `FLAME_ENABLE_WEB_INTERFACE` | `FlameWeb.*` (Phoenix LiveView) |
| HTTP worker server | `FLAME_ENABLE_WORKER_SERVER` | `FlameWorkerServer` |

### Optional dependencies

The web dashboard requires Phoenix and LiveView. Add them to your deps if you
want the dashboard:

```elixir
{:phoenix, "~> 1.7.0"},
{:phoenix_live_view, "~> 0.20.0"},
{:phoenix_live_dashboard, "~> 0.8"},
{:plug_cowboy, "~> 2.6"}
```

HTTP features (alerting webhooks, cluster health checks) use
[Req](https://hex.pm/packages/req):

```elixir
{:req, "~> 0.5.0"}
```

## Configuration

All configuration is read from environment variables at runtime
(twelve-factor style). Copy `.env.example` to `.env` and adjust for your
environment:

```bash
cp .env.example .env
```

Key variables:

```bash
# Core
FLAME_ERLANG_COOKIE=your_secret_cookie
FLAME_IMAGE=flame-worker:latest
FLAME_DNS_DOMAIN=flame.local

# Pool sizing
FLAME_POOL_MIN=0
FLAME_POOL_MAX=5
FLAME_POOL_MAX_CONCURRENCY=10

# Feature flags
FLAME_ENABLE_METRICS=true
FLAME_ENABLE_SECURITY=true
FLAME_ENABLE_WEB_INTERFACE=false
FLAME_ENABLE_ORCHESTRATION=true

# Web dashboard (when enabled)
FLAME_WEB_PORT=4001
SECRET_KEY_BASE=generate_a_64_byte_secret
```

See [`.env.example`](.env.example) for the full list of available variables.

You can also configure via your application's config:

```elixir
config :flame_apple_container_backend,
  allowed_worker_modules: [MyApp.Workers.ImageProcessor, MyApp.Workers.DataCruncher]
```

## Development

This project uses [mise](https://mise.jdx.dev) for tool management.
After cloning, run:

```bash
mise install    # Install Erlang 27 + Elixir 1.18
cp .env.example .env
mise run deps   # Install dependencies
mise run ci     # Run full CI pipeline (compile + format + test + lint)
```

See `mise tasks` for all available tasks.

## License

MIT License - see [LICENSE](LICENSE) for details.
