import Config

# Runtime configuration — reads from environment variables.
# Pool and backend settings are handled by FLAME.AppleContainers.Config,
# which merges defaults, application config, and FLAME_* environment variables.

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
