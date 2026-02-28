# FLAME Worker Environment Variables

When the Apple Containers backend starts a FLAME worker, it configures the
container through environment variables. Some are set automatically by the
backend; others must be provided by the application.

## Auto-set by the backend

These variables are injected into every worker container by `remote_boot/1`.
Do **not** hardcode them in your Dockerfile or release config.

| Variable | Value | Purpose |
|---|---|---|
| `FLAME_PARENT` | Encoded parent struct | Tells the worker how to connect back to the parent node |
| `FLAME_HOST` | Container FQDN (`<name>.<dns_domain>`) | Hostname used for distributed Erlang and DNS discovery |
| `PHX_SERVER` | `false` | Prevents the Phoenix HTTP listener from starting on workers |
| `RELEASE_DISTRIBUTION` | `name` | Enables longname distributed Erlang (required for cross-host clustering) |
| `RELEASE_NODE` | `<container_name>@<fqdn>` | Full node name for distributed Erlang |
| `RELEASE_COOKIE` | Erlang cookie string | Must match the parent node for cluster authentication |

## User-provided via `:env` config

Pass additional environment variables through the `:env` option in your backend
configuration. These are appended after the auto-set variables.

```elixir
config :flame, FLAME.AppleContainersBackend,
  image: "my-app-worker:latest",
  env: [
    {"SECRET_KEY_BASE", "..."},
    {"DATABASE_URL", "ecto://user:pass@host/db"}
  ]
```

Which variables you need depends on what your worker starts at boot.

### SECRET_KEY_BASE

**Required if** your worker starts a Phoenix Endpoint (the default when your
app includes one in its supervision tree).

Phoenix requires `SECRET_KEY_BASE` for signing cookies and tokens even when
`PHX_SERVER=false` disables HTTP serving. Pass it via `:env`:

```elixir
env: [
  {"SECRET_KEY_BASE", "your-64+-byte-secret"}
]
```

### DATABASE_URL

**Required if** your worker starts an Ecto Repo that connects to an external
database. This depends on your database backend:

| Database | Worker needs `DATABASE_URL`? | Notes |
|---|---|---|
| PostgreSQL | Yes, if the Repo starts on workers | Workers must reach the database server over the network |
| SQLite | No | The database file does not exist inside the container. Use the conditional Repo pattern below to skip it. |
| None | No | No database configuration needed |

## Conditional Repo pattern

FLAME workers are typically compute-only -- they run your functions but do not
need their own database connection. Skipping the Repo on workers avoids
unnecessary connections and removes the need for `DATABASE_URL` entirely.

The pattern uses the `FLAME_PARENT` environment variable, which is only set
on worker containers, to detect whether the current process is a worker.

### application.ex

Conditionally include the Repo in the supervision tree:

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    base_children = [
      MyAppWeb.Telemetry,
      {Phoenix.PubSub, name: MyApp.PubSub},
      {FLAME.Pool,
       name: MyApp.WorkerPool,
       min: 0,
       max: 10,
       max_concurrency: 5,
       idle_shutdown_after: 30_000},
      MyAppWeb.Endpoint
    ]

    children =
      if System.get_env("FLAME_PARENT") do
        # Worker: skip database
        base_children
      else
        # Parent: start the Repo
        [MyApp.Repo | base_children]
      end

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### runtime.exs

Guard database configuration so it is only required on the parent node:

```elixir
if config_env() == :prod do
  # Only require DATABASE_URL on the parent node
  unless System.get_env("FLAME_PARENT") do
    database_url =
      System.get_env("DATABASE_URL") ||
        raise "environment variable DATABASE_URL is missing"

    config :my_app, MyApp.Repo,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
  end

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing"

  config :my_app, MyAppWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST") || "example.com"],
    secret_key_base: secret_key_base
end
```

## Configuration examples

### Minimal (compute-only workers, no database)

Workers only need the auto-set variables. If your Endpoint requires
`SECRET_KEY_BASE`, pass it:

```elixir
config :flame, FLAME.AppleContainersBackend,
  image: "my-app:latest",
  env: [
    {"SECRET_KEY_BASE", System.get_env("SECRET_KEY_BASE")}
  ]
```

### With PostgreSQL database on workers

If your workers need direct database access:

```elixir
config :flame, FLAME.AppleContainersBackend,
  image: "my-app:latest",
  env: [
    {"SECRET_KEY_BASE", System.get_env("SECRET_KEY_BASE")},
    {"DATABASE_URL", System.get_env("DATABASE_URL")}
  ]
```

### Standalone worker image (no Phoenix)

If your worker image does not include a Phoenix Endpoint, no user-provided
environment variables are needed. The backend auto-sets everything:

```elixir
config :flame, FLAME.AppleContainersBackend,
  image: "flame-worker:latest"
```

See `docs/examples/flame_worker/` for a complete standalone worker example.
