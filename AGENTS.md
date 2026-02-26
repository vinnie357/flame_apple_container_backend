# AGENTS.md

Project conventions and instructions for AI agents working on this codebase.

## Project

**flame_apple_container_backend** — A FLAME backend for macOS Apple Containers,
published as a Hex package.

- Language: Elixir ~> 1.15
- Build: Mix
- Package manager: Hex
- Dev tools: mise (see mise.toml)

## Code style

- Follow standard Elixir conventions (`mix format`)
- No `Code.eval_string` — use MFA tuples or function references for dynamic dispatch
- Prefer `Application.get_env` and configurable callbacks over hardcoded values
- Optional dependencies must be guarded with `Code.ensure_loaded?/1`
- No mock/stub implementations in production code — use adapter patterns or
  configurable callbacks instead

## Git conventions

- Single-line commits: `type(scope): description`
- Types: feat, fix, docs, refactor, test, chore
- No attribution lines (no Co-Authored-By)
- No commit bodies or footers for routine work
- Branch naming: `type/short-description`

## Development workflow

This project uses [mise](https://mise.jdx.dev) to manage tool versions
(Erlang, Elixir) and development tasks. Run `mise install` after cloning to
set up the correct tool versions automatically.

### Available mise tasks

Run `mise tasks` to see all available tasks. Key tasks:

| Task | Description | Command |
|------|-------------|---------|
| `mise run deps` | Install dependencies | `mix deps.get` |
| `mise run compile` | Compile the project | `mix compile` |
| `mise run test` | Run tests | `mix test` |
| `mise run format` | Format code | `mix format` |
| `mise run format-check` | Check formatting | `mix format --check-formatted` |
| `mise run lint` | Run credo linter | `mix credo --strict` |
| `mise run docs` | Generate documentation | `mix docs` |
| `mise run hex-build` | Build Hex package | `mix hex.build` |
| **`mise run ci`** | **Full CI pipeline** | compile + format-check + test + lint |

### Before committing

**Always run `mise run ci` before committing.** This is the single command that
validates everything: compilation, formatting, tests, and linting. It replaces
running individual mix commands manually.

```bash
mise run ci
```

Reserve individual `mix` commands (`mix test`, `mix compile`, etc.) for
troubleshooting specific failures. The `ci` task is the authoritative check.

## Testing

- Tests must pass (`mise run ci`) before committing
- Tests live in `test/` mirroring the `lib/` structure
- Use ExUnit with `async: true` where possible
- Integration tests that need Apple Containers should be tagged `@tag :integration`

## Architecture

- `lib/flame/apple_containers_backend.ex` — FLAME backend (Runner protocol)
- `lib/flame/apple_containers/cli.ex` — CLI behaviour + adapter pattern
- `lib/flame/apple_containers/cli/system.ex` — real CLI adapter
- `lib/flame/apple_containers/cli/mock.ex` — test mock (process dictionary)
- `config/` — environment-specific configuration

## Dependencies

- Core: flame, jason, telemetry
- Dev only: ex_doc, credo, tidewave, bandit

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
- you can't close anything that doesn't follow TDD, all features will have tests, and ci will pass before closing or commiting. so that all commits are clean, and nothing is "done" until it has tests.  