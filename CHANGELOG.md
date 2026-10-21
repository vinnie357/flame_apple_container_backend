# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-10-21

### Security

- Added a `mix hex.audit` CI gate (`mise run audit:hex`, Hex 2.5.3 or newer). It
  fails on any advisory or retirement not allow-listed in `mix.exs`
  (`hex: [ignore_advisories: []]`) and on a stale allow-list entry.
- Added a `mix deps.audit` CI gate (`mise run audit:deps`, mix_audit). It fails
  on any finding not in `.mix-audit-ignore`, on a stale entry, on a missing or
  unreadable `mix.lock`, on an empty advisory database, and when its
  positive-control lock is not flagged.
- Added `docs/security/advisory-exceptions.md`, the policy for allow-listing an
  advisory with a STRIDE review, and `mise run audit:advisory-doc`, which fails
  once an exception's review is overdue. Both allow-lists are empty.
- Cleared 31 `mix hex.audit` advisories (bandit 11, mint 13, plug 4, req 2,
  hpax 1) by updating dependencies. `mix hex.audit` and `mix deps.audit` now
  report none.

### Fixed

- `build_image/1` in `CLI.System` now invokes `container build` (top-level
  subcommand) instead of the removed `container image build` subcommand, which
  was dropped in Apple Container CLI 1.0.0.
- `run_container/1` in `CLI.System` now passes `stderr_to_stdout: true` so that
  CLI error output (printed to stderr by `container run`) is captured and
  available in the return value; previously dropped stderr gutted failure
  diagnostics in `FLAME.AppleContainersBackend.remote_boot/1`.

### Changed

- Updated dependencies: flame 0.5.3 to 0.5.4, telemetry 1.3.0 to 1.4.2, jason
  1.4.4 to 1.4.5, and in dev bandit 1.10.3 to 1.13.1, plug 1.19.1 to 1.20.3
  and tidewave 0.5.5 to 0.9.1 (constraint `~> 0.9`). flame 0.5.4 changes only
  the TLS verification depth in `FLAME.FlyBackend`, which this backend does not
  use.
- req, mint, finch, nimble_pool and nimble_options are no longer locked; tidewave
  0.9 no longer depends on them. tidewave 0.9 adds websock_adapter.
- Added mix_audit (dev and test only) and pinned nushell 0.113.1 in mise for the
  audit scripts.
- CI pins its actions by commit SHA (checkout v7.0.1, mise-action v5.2.2, cache
  v6.1.0), passes `GITHUB_TOKEN` to mise-action, and allows 10 minutes.
- Integration test suite (`test/cli_system_integration_test.exs`) now requires
  container CLI 1.0.0+.
- Added `test/fixtures/cli/1.0.0/` with read-only command captures from the
  real container CLI 1.0.0 (`ee848e3`): `dns_list`, `image_list`,
  `list_containers`, `inspect_not_found`, `stop_not_found`, `kill_not_found`,
  `exec_not_found`, `stats_not_found`, `build_help`, `hostname`.

### Removed

- Security subsystem (RBAC, policy engine, compliance manager, audit logger)
- Monitoring modules (container metrics, health checks, circuit breaker, alerting)
- Orchestration modules (task scheduling, cluster management, image lifecycle)
- Phoenix LiveView web dashboard
- HTTP-based worker server
- OTP application supervisor — library no longer starts supervised children
- Optional dependencies: Phoenix, Floki, Prometheus, Fuse, gen_state_machine, Req

## [0.1.0] - 2026-02-21

### Added

- FLAME backend for macOS Apple Containers (`FLAME.AppleContainersBackend`)
- CLI behaviour with adapter pattern for testability
- Container lifecycle management via `container` CLI
