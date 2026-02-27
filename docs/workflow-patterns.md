# Workflow Execution Patterns

This guide covers common patterns for running workloads inside Apple Containers
using the FLAME backend.

## Prerequisites

A running FLAME pool configured with the Apple Containers backend:

```elixir
# In your supervision tree
children = [
  {FLAME.Pool,
   name: MyApp.WorkerPool,
   backend: FLAME.AppleContainersBackend,
   min: 0,
   max: 10,
   max_concurrency: 5,
   idle_shutdown_after: 30_000}
]
```

## Pattern 1: Synchronous Work (`FLAME.call/3`)

Run a function inside a container and wait for the result. The most common
pattern — use it when you need the return value.

```elixir
result = FLAME.call(MyApp.WorkerPool, fn ->
  # This runs inside an Apple Container
  heavy_computation()
end)
```

### Extended Timeouts

The default timeout is 30 seconds. Override per-call for long-running work:

```elixir
result = FLAME.call(MyApp.WorkerPool, fn ->
  # Clone, build, test — might take a while
  System.cmd("git", ["clone", repo_url])
  System.cmd("mix", ["test"], cd: repo_path)
end, timeout: 300_000)  # 5 minutes
```

Or set the pool default:

```elixir
{FLAME.Pool,
 name: MyApp.WorkerPool,
 backend: FLAME.AppleContainersBackend,
 timeout: 120_000,  # 2 minute default
 ...}
```

### Unlinked Calls

By default, if the caller process dies, the remote work is killed too.
Use `link: false` when the work should finish regardless:

```elixir
result = FLAME.call(MyApp.WorkerPool, fn ->
  # Will complete even if the calling process crashes
  build_and_push_artifact()
end, link: false)
```

## Pattern 2: Fire-and-Forget (`FLAME.cast/3`)

Send work to a container without waiting. Returns `:ok` immediately.
The function runs to completion with no timeout.

```elixir
:ok = FLAME.cast(MyApp.WorkerPool, fn ->
  send_notifications()
  upload_logs()
end)
```

Use `link: false` for work that should survive the caller:

```elixir
:ok = FLAME.cast(MyApp.WorkerPool, fn ->
  cleanup_old_artifacts()
end, link: false)
```

## Pattern 3: Long-Lived Processes (`FLAME.place_child/3`)

Start a supervised child process on a remote container node. Useful for
stateful workers, listeners, or multi-step workflows managed by a GenServer.

```elixir
{:ok, worker_pid} = FLAME.place_child(MyApp.WorkerPool, {MyWorker, [task: task_spec]})
```

The child process keeps the container alive as long as it runs. When the child
exits, the container can be reclaimed by the pool.

### Workflow GenServer Example

A GenServer that manages a multi-step workflow inside a container:

```elixir
defmodule MyApp.WorkflowRunner do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    repo = Keyword.fetch!(opts, :repo)
    send(self(), :run)
    {:ok, %{repo: repo, step: :clone}}
  end

  @impl true
  def handle_info(:run, %{step: :clone, repo: repo} = state) do
    {_, 0} = System.cmd("git", ["clone", repo, "/tmp/work"])
    send(self(), :run)
    {:noreply, %{state | step: :build}}
  end

  def handle_info(:run, %{step: :build} = state) do
    {_, 0} = System.cmd("mix", ["compile"], cd: "/tmp/work")
    send(self(), :run)
    {:noreply, %{state | step: :test}}
  end

  def handle_info(:run, %{step: :test} = state) do
    {output, exit_code} = System.cmd("mix", ["test"], cd: "/tmp/work")
    # Report results back, then stop
    {:stop, :normal, %{state | step: :done, result: {output, exit_code}}}
  end
end
```

Place it on a container:

```elixir
{:ok, pid} = FLAME.place_child(MyApp.WorkerPool,
  {MyApp.WorkflowRunner, [repo: "https://github.com/org/repo.git"]},
  timeout: 600_000)
```

## Pattern 4: Parallel Fan-Out

Spawn multiple containers to process work concurrently:

```elixir
tasks =
  Enum.map(repos, fn repo ->
    Task.async(fn ->
      FLAME.call(MyApp.WorkerPool, fn ->
        run_analysis(repo)
      end, timeout: 120_000)
    end)
  end)

results = Task.await_many(tasks, 300_000)
```

The pool's `max` setting controls how many containers run simultaneously.
Each task checks out a runner from the pool.

## Use Cases

### CI Pipeline in a Container

```elixir
FLAME.call(MyApp.BuildPool, fn ->
  System.cmd("git", ["clone", "--depth", "1", repo_url, "/tmp/build"])
  {_, 0} = System.cmd("mix", ["deps.get"], cd: "/tmp/build")
  {_, 0} = System.cmd("mix", ["compile", "--warnings-as-errors"], cd: "/tmp/build")
  {output, exit_code} = System.cmd("mix", ["test"], cd: "/tmp/build")
  %{output: output, exit_code: exit_code}
end, timeout: 300_000)
```

### Isolated Code Execution

Run untrusted or experimental code in a throwaway container:

```elixir
result = FLAME.call(MyApp.SandboxPool, fn ->
  # Container is destroyed after this returns
  Code.eval_string(user_code)
end)
```

### Volume-Mounted Workflows

Share data between host and container using volumes:

```elixir
# Pool config
{FLAME.Pool,
 name: MyApp.DataPool,
 backend: {FLAME.AppleContainersBackend, [
   image: "data-worker:latest",
   volumes: ["/host/data:/app/data:ro"]
 ]},
 min: 0,
 max: 5}

# Use it
FLAME.call(MyApp.DataPool, fn ->
  File.read!("/app/data/input.csv")
  |> process_data()
end)
```

## Configuration Reference

Backend options passed to `FLAME.AppleContainersBackend`:

| Option | Default | Description |
|--------|---------|-------------|
| `:image` | `"flame-worker:latest"` | Container image to run |
| `:dns_domain` | `"flame.local"` | DNS domain for name resolution |
| `:container_prefix` | `"flame-worker"` | Prefix for container names |
| `:erlang_cookie` | `Node.get_cookie()` | Distributed Erlang cookie |
| `:boot_timeout` | `30_000` | Container boot timeout (ms) |
| `:env` | `[]` | Extra env vars (`[{"K","V"}]` or `["K=V"]`) |
| `:volumes` | `[]` | Volume mounts (`["host:container:opts"]`) |
| `:network_name` | `"flame-cluster-net"` | Network for clustering |
| `:enable_clustering` | `false` | Enable container networking |
| `:log` | `false` | Log level for backend messages |

Pool options (from FLAME itself):

| Option | Default | Description |
|--------|---------|-------------|
| `:min` | — | Minimum idle runners (`0` for scale-to-zero) |
| `:max` | — | Maximum runners |
| `:max_concurrency` | `100` | Concurrent executions per runner |
| `:timeout` | `30_000` | Default call timeout (ms) |
| `:idle_shutdown_after` | `30_000` | Idle time before shutdown (ms) |
| `:single_use` | `false` | Terminate runner after each call |
