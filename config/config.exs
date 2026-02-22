import Config

# Compile-time configuration only. No secrets here.
# All runtime config comes from environment variables via runtime.exs.

config :phoenix, :json_library, Jason

# Import environment specific config
case config_env() do
  :dev -> import_config("dev.exs")
  :test -> import_config("test.exs")
  :prod -> import_config("prod.exs")
  _ -> :ok
end
