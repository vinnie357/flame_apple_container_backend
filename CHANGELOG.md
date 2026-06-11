# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `build_image/1` in `CLI.System` now invokes `container build` (top-level
  subcommand) instead of the removed `container image build` subcommand, which
  was dropped in Apple Container CLI 1.0.0.
- `run_container/1` in `CLI.System` now passes `stderr_to_stdout: true` so that
  CLI error output (printed to stderr by `container run`) is captured and
  available in the return value; previously dropped stderr gutted failure
  diagnostics in `FLAME.AppleContainersBackend.remote_boot/1`.

### Changed

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
