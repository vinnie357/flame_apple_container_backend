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

## Development

This project uses [mise](https://mise.jdx.dev) for tool management.
After cloning, run:

```bash
mise install    # Install Erlang 27 + Elixir 1.19
mise run deps   # Install dependencies
mise run ci     # Run full CI pipeline (compile + format + test + lint)
```

See `mise tasks` for all available tasks.

## License

MIT License - see [LICENSE](LICENSE) for details.
