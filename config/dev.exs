import Config

# Development environment configuration
config :logger, level: :info

# Configure Phoenix endpoint for development
config :flame_apple_container_backend, FlameWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4001],
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  watchers: []

# Configure development environment
config :flame_apple_container_backend,
  dev_mode: true