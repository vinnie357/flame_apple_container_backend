# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
