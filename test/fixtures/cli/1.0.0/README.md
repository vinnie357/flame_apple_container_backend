# CLI 1.0.0 Response Fixtures

Captured from `container CLI version 1.0.0 (build: release, commit: ee848e3)`.

Each `.json` file contains `{"stdout": ..., "exit_code": ...}` representing
the `{output, exit_code}` tuple returned by `System.cmd/3`.

## Key differences from 0.9.0

### Build command moved to top level

`container build` is now a **top-level subcommand** — `container image build` is REMOVED in 1.0.0.

```
# 1.0.0 (correct)
container build -t myimage:latest .

# 0.9.0 (no longer works)
container image build -t myimage:latest .   # exits 64
```

### System configuration via TOML

`container system property get/set/clear` are REMOVED in 1.0.0. Configuration
now lives in `~/.config/container/config.toml` (falls back to
`<installRoot>/etc/container/config.toml`). Restart the service after editing.

`container system property list` (alias `ls`) remains as read-only view of the
merged configuration.

### Structured output available

`--format json` is available on list/inspect/stats operations, e.g.:

```
container list --format json
container inspect <name> --format json
container stats <name> --format json
```

### Error handling changes (BREAKING)

Several commands return **exit code 1** for nonexistent containers in 1.0.0
where 0.9.0 returned exit code 0:

| Command | 0.9.0 | 1.0.0 |
|---------|-------|-------|
| `container inspect <nonexistent>` | exit 0, stdout `[]` | exit 1, error message |
| `container stop <nonexistent>` | exit 0, no output | exit 1, error message |
| `container kill <nonexistent>` | exit 0, no output | exit 1, error message |

Error message formats also changed:

| Command | 0.9.0 error | 1.0.0 error |
|---------|------------|------------|
| `container exec <nonexistent> ...` | `notFound: "..."` | `get failed: container ... not found` |
| `container stats <nonexistent> ...` | `notFound: "no such container: ..."` | `no such container: ...` |

### Version string

```
container CLI version 1.0.0 (build: release, commit: ee848e3)
```

## Captured fixtures

| File | Command | Notes |
|------|---------|-------|
| `dns_list.json` | `container system dns list` | Header + domain list |
| `image_list.json` | `container image ls` | Header + representative image rows |
| `list_containers.json` | `container list` | Header + running containers (buildkit shown) |
| `inspect_not_found.json` | `container inspect <nonexistent>` | exit 1 in 1.0.0 |
| `stop_not_found.json` | `container stop <nonexistent>` | exit 1 in 1.0.0 |
| `kill_not_found.json` | `container kill <nonexistent>` | exit 1 in 1.0.0 |
| `exec_not_found.json` | `container exec <nonexistent> echo test` | exit 1, changed error format |
| `stats_not_found.json` | `container stats <nonexistent> --no-stream` | exit 1, changed error format |
| `build_help.json` | `container build --help` | Top-level build subcommand |
| `hostname.json` | `hostname` | Host FQDN |

## Running-container captures not included

Running-container captures (run, exec success, stats success, stop success, etc.)
were not refreshed for 1.0.0 and remain in `0.9.0/`. The container lifecycle
behavior (when containers exist) is unchanged.

## Integration suite requirements

The integration test suite (`test/cli_system_integration_test.exs`) requires
container CLI 1.0.0+. Run with:

```
mix test --include integration
```
