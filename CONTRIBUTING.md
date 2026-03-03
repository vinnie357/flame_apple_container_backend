# Contributing to FlameAppleContainerBackend

Thank you for your interest in contributing!

## Getting Started

1. Fork and clone the repo
2. Install [mise](https://mise.jdx.dev) for tool management
3. Run setup:

```bash
mise install          # Install Erlang + Elixir
mise run deps         # Install dependencies
mise run ci           # Run full CI pipeline
```

## Development

### Running Tests

```bash
mise run test         # Unit tests (excludes integration)
mise run cover        # Tests with coverage report
```

Integration tests require macOS 26+ with Apple Container support:

```bash
mix test --include integration
```

### Linting

```bash
mise run lint         # Format check + credo
mise run format       # Auto-format
```

### Pre-commit Checks

```bash
mise run precommit    # Secrets scan + lint
```

## How to Contribute

### Bug Reports

- Use the [bug report template](https://github.com/vinnie357/flame_apple_container_backend/issues/new?template=bug_report.yml)
- Include reproduction steps and version info
- Attach relevant logs or error output

### Feature Requests

- Use the [feature request template](https://github.com/vinnie357/flame_apple_container_backend/issues/new?template=feature_request.yml)
- Describe the use case and expected behavior

### Pull Requests

1. Branch from `main`
2. Follow existing code style (enforced by `mix format` and `mix credo --strict`)
3. Write tests for new functionality
4. Ensure `mise run ci` passes
5. Use [conventional commits](https://www.conventionalcommits.org/) for commit messages
6. Reference related issues in the PR description

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
