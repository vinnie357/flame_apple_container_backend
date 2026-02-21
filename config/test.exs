import Config

# Disable logger completely during tests
config :logger,
  level: :emergency,
  compile_time_purge_matching: [[level_lower_than: :emergency]],
  backends: []

# Disable console handler during tests
config :logger, :console, level: :emergency

# Configure test environment to be quiet
config :flame_apple_container_backend,
  test_mode: true,
  log_level: :emergency

# Configure Phoenix endpoint for tests
config :flame_apple_container_backend, FlameWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_for_testing_only",
  live_view: [signing_salt: "test_salt"],
  server: false

# Configure ExUnit to capture logs and keep them quiet
config :ex_unit,
  capture_log: true,
  colors: [enabled: true]

# Ensure Floki is available for LiveView tests
config :floki, :html_parser, Floki.HTMLParser.Mochiweb

# Phoenix LiveView configuration for tests
config :phoenix_live_view, :debug_heex_annotations, false