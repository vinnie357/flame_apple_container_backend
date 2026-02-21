# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-02-21

### Added

- FLAME backend for macOS Apple Containers (`FLAME.AppleContainersBackend`)
- Container lifecycle management (start, stop, monitor, pool)
- Security subsystem: RBAC, policy engine, compliance manager, audit logger
- Monitoring: container metrics, health checks, circuit breaker, alerting
- Orchestration: task scheduling, cluster management, image lifecycle
- Optional Phoenix LiveView web dashboard
- HTTP-based worker server as alternative to Erlang distribution
- Configurable feature flags via `FLAME_*` environment variables
