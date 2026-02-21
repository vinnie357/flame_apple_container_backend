import Config

# Runtime configuration — reads from environment variables.
# See .env.example for all available variables.

# --- Logging ---
if log_level = System.get_env("LOG_LEVEL") do
  config :logger, level: String.to_existing_atom(log_level)
end

# --- Phoenix Web Dashboard ---
if System.get_env("FLAME_ENABLE_WEB_INTERFACE") == "true" do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is required when FLAME_ENABLE_WEB_INTERFACE=true"

  port = String.to_integer(System.get_env("FLAME_WEB_PORT") || "4001")
  signing_salt = System.get_env("LIVE_VIEW_SIGNING_SALT") || "default_salt"

  config :flame_apple_container_backend, FlameWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: port],
    secret_key_base: secret_key_base,
    live_view: [signing_salt: signing_salt],
    pubsub_server: FlameWeb.PubSub,
    render_errors: [accepts: ~w(html json), layout: false],
    check_origin: false
end

# --- FLAME Pool Configuration ---
config :flame_apple_container_backend,
  flame_pool: %{
    min: String.to_integer(System.get_env("FLAME_POOL_MIN") || "0"),
    max: String.to_integer(System.get_env("FLAME_POOL_MAX") || "5"),
    max_concurrency: String.to_integer(System.get_env("FLAME_POOL_MAX_CONCURRENCY") || "10"),
    boot_timeout: String.to_integer(System.get_env("FLAME_BOOT_TIMEOUT") || "60000"),
    idle_shutdown_after: String.to_integer(System.get_env("FLAME_IDLE_SHUTDOWN_AFTER") || "30000")
  },
  flame_backend: %{
    image: System.get_env("FLAME_IMAGE") || "flame-worker:latest",
    erlang_cookie: System.get_env("FLAME_ERLANG_COOKIE") || "change_me",
    dns_domain: System.get_env("FLAME_DNS_DOMAIN") || "flame.local",
    container_prefix: System.get_env("FLAME_CONTAINER_PREFIX") || "flame-worker"
  }
