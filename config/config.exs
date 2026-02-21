import Config

# Basic configuration for FLAME worker
config :logger, level: :info

# Configure the application
config :flame_apple_container_backend,
  ecto_repos: []

# Phoenix endpoint configuration for dashboard
config :flame_apple_container_backend, FlameWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4001],
  secret_key_base: "6eKv6BRu8iTQ8LkiXwNqIEJQn6JkW7FuJ2HpNktIVJ2LxSkqHqR4B1Jg8n5HdN0J",
  live_view: [signing_salt: "VGhUQ1pH"],
  pubsub_server: FlameWeb.PubSub,
  render_errors: [view: FlameWeb.ErrorView, accepts: ~w(html json), layout: false],
  check_origin: false

config :phoenix, :json_library, Jason

# Configure PubSub
config :flame_apple_container_backend, FlameWeb.PubSub,
  name: FlameWeb.PubSub,
  adapter: Phoenix.PubSub.PG2

# Import environment specific config
case config_env() do
  :dev -> import_config "dev.exs"
  :test -> import_config "test.exs"
  :prod -> import_config "prod.exs"
  _ -> :ok
end
