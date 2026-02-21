import Config

config :logger, level: :emergency

config :flame_apple_container_backend,
  test_mode: true,
  flame_pool: %{
    min: 0,
    max: 5,
    max_concurrency: 10,
    boot_timeout: 60_000,
    idle_shutdown_after: 30_000
  },
  flame_backend: %{
    image: "flame-worker:test",
    erlang_cookie: "test_cookie",
    dns_domain: "test.local",
    container_prefix: "test-flame"
  }

config :flame_apple_container_backend, FlameWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "test_secret_key_base_for_testing_only_this_must_be_at_least_64_bytes_long_to_work_properly",
  live_view: [signing_salt: "test_salt"],
  server: false

config :ex_unit,
  capture_log: true

config :floki, :html_parser, Floki.HTMLParser.Mochiweb

config :phoenix_live_view, :debug_heex_annotations, false
