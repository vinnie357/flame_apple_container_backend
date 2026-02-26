import Config

config :logger, level: :warning

config :flame_apple_container_backend, :cli_adapter, FLAME.AppleContainers.CLI.Mock

config :ex_unit,
  capture_log: true
