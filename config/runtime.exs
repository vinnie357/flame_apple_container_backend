import Config

# Configure FLAME_WEB_PORT for all environments
if flame_web_port = System.get_env("FLAME_WEB_PORT") do
  port = String.to_integer(flame_web_port)
  config :flame_apple_container_backend, FlameWeb.Endpoint, http: [port: port]
end