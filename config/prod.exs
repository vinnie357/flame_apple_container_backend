import Config

# Production environment configuration
config :logger, level: :info

# Configure Phoenix endpoint for production
config :flame_apple_container_backend, FlameWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4001],
  server: true

# Configure production environment
config :flame_apple_container_backend,
  prod_mode: true