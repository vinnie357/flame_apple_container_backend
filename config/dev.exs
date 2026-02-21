import Config

config :logger, level: :info

config :flame_apple_container_backend, FlameWeb.Endpoint,
  debug_errors: true,
  code_reloader: true,
  watchers: []
