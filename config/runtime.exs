import Config

if log_level = System.get_env("LOG_LEVEL") do
  config :logger, level: String.to_existing_atom(log_level)
end
