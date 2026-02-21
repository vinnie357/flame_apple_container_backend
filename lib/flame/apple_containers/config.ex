defmodule FLAME.AppleContainers.Config do
  @moduledoc """
  Configuration management for FLAME Apple Containers backend.

  This module provides a centralized way to manage configuration for all
  components of the Apple Containers backend, including validation,
  environment variable handling, and default values.

  ## Configuration Sources

  Configuration is loaded from multiple sources in order of precedence:
  1. Runtime options passed to functions
  2. Environment variables (FLAME_*)
  3. Application configuration (config.exs)
  4. Default values

  ## Environment Variables

  The following environment variables are supported:

  - `FLAME_IMAGE` - Container image to use
  - `FLAME_POOL_SIZE` - Initial pool size
  - `FLAME_MAX_POOL_SIZE` - Maximum pool size
  - `FLAME_DNS_DOMAIN` - DNS domain for container networking
  - `FLAME_ERLANG_COOKIE` - Erlang cookie for distributed connections
  - `FLAME_HEALTH_CHECK_INTERVAL` - Health check frequency in milliseconds
  - `FLAME_TASK_TIMEOUT` - Task execution timeout in milliseconds
  - `FLAME_RETRY_ATTEMPTS` - Number of retry attempts for failed tasks
  - `FLAME_ENABLE_MONITORING` - Enable health monitoring
  - `FLAME_ENABLE_METRICS` - Enable metrics collection
  - `FLAME_LOG_LEVEL` - Logging level

  ## Configuration Examples

      # Get default configuration
      config = FLAME.AppleContainers.Config.load()
      
      # Get configuration with overrides
      config = FLAME.AppleContainers.Config.load([
        pool_size: 5,
        image: "my-worker:latest"
      ])
      
      # Validate configuration
      :ok = FLAME.AppleContainers.Config.validate(config)
  """

  require Logger

  @type config_key :: atom()
  @type config_value :: any()
  @type config_map :: %{config_key() => config_value()}
  @type config_opts :: [{config_key(), config_value()}]

  @default_config %{
    # Container configuration
    image: "flame-worker:latest",
    dns_domain: "flame.local",
    container_prefix: "flame-worker",
    erlang_cookie: nil,

    # Pool configuration
    pool_size: 3,
    max_pool_size: 10,
    min_pool_size: 1,

    # Resource limits
    resource_limits: %{
      memory: "512m",
      cpu: "1.0"
    },

    # Task execution
    # 5 minutes
    task_timeout: 300_000,
    retry_attempts: 3,
    # 1 second
    retry_backoff: 1000,

    # Health monitoring
    # 30 seconds
    health_check_interval: 30_000,
    # 1 minute
    metrics_collection_interval: 60_000,
    enable_monitoring: true,
    enable_metrics: true,
    enable_recovery: true,

    # Alert thresholds
    alert_thresholds: %{
      cpu_usage: 80.0,
      memory_usage: 85.0,
      error_rate: 5.0,
      response_time: 5000,
      unhealthy_containers: 0.3
    },

    # Logging and debugging
    log_level: :info,
    debug_mode: false,

    # Security
    enable_security: true,
    audit_logging: false,

    # Performance
    auto_scale: true,
    scale_up_threshold: 0.8,
    scale_down_threshold: 0.2,
    # 1 minute
    scale_cooldown: 60_000,

    # Development and testing
    mode: :production,
    test_mode: false,
    mock_containers: false
  }

  @required_keys [:image]

  @env_var_mappings %{
    "FLAME_IMAGE" => :image,
    "FLAME_POOL_SIZE" => :pool_size,
    "FLAME_MAX_POOL_SIZE" => :max_pool_size,
    "FLAME_DNS_DOMAIN" => :dns_domain,
    "FLAME_ERLANG_COOKIE" => :erlang_cookie,
    "FLAME_HEALTH_CHECK_INTERVAL" => :health_check_interval,
    "FLAME_TASK_TIMEOUT" => :task_timeout,
    "FLAME_RETRY_ATTEMPTS" => :retry_attempts,
    "FLAME_ENABLE_MONITORING" => :enable_monitoring,
    "FLAME_ENABLE_METRICS" => :enable_metrics,
    "FLAME_LOG_LEVEL" => :log_level,
    "FLAME_DEBUG_MODE" => :debug_mode,
    "FLAME_AUTO_SCALE" => :auto_scale,
    "FLAME_MODE" => :mode,
    "FLAME_TEST_MODE" => :test_mode
  }

  @doc """
  Loads configuration from all sources with optional overrides.

  ## Parameters

  - `overrides` - Keyword list of configuration overrides (optional)

  ## Returns

  A configuration map with all settings resolved.

  ## Examples

      # Load default configuration
      config = FLAME.AppleContainers.Config.load()
      
      # Load with overrides
      config = FLAME.AppleContainers.Config.load([
        pool_size: 8,
        image: "custom-worker:v2.0"
      ])
  """
  @spec load(config_opts()) :: config_map()
  def load(overrides \\ []) do
    @default_config
    |> merge_application_config()
    |> merge_environment_variables()
    |> merge_overrides(overrides)
    |> ensure_required_values()
    |> normalize_config()
  end

  @doc """
  Validates a configuration map.

  ## Parameters

  - `config` - Configuration map to validate

  ## Returns

  - `:ok` - Configuration is valid
  - `{:error, reason}` - Configuration is invalid

  ## Examples

      config = FLAME.AppleContainers.Config.load()
      :ok = FLAME.AppleContainers.Config.validate(config)
  """
  @spec validate(config_map()) :: :ok | {:error, term()}
  def validate(config) when is_map(config) do
    with :ok <- validate_required_keys(config),
         :ok <- validate_pool_configuration(config),
         :ok <- validate_resource_limits(config),
         :ok <- validate_timeouts(config),
         :ok <- validate_thresholds(config) do
      :ok
    end
  end

  def validate(_config) do
    {:error, :invalid_config_type}
  end

  @doc """
  Gets a specific configuration value with a fallback.

  ## Parameters

  - `config` - Configuration map
  - `key` - Configuration key to retrieve
  - `default` - Default value if key is not found

  ## Returns

  The configuration value or default.

  ## Examples

      config = FLAME.AppleContainers.Config.load()
      pool_size = FLAME.AppleContainers.Config.get(config, :pool_size, 3)
  """
  @spec get(config_map(), config_key(), config_value()) :: config_value()
  def get(config, key, default \\ nil) do
    Map.get(config, key, default)
  end

  @doc """
  Updates a configuration value.

  ## Parameters

  - `config` - Configuration map to update
  - `key` - Configuration key to update
  - `value` - New value

  ## Returns

  Updated configuration map.

  ## Examples

      config = FLAME.AppleContainers.Config.load()
      updated_config = FLAME.AppleContainers.Config.put(config, :pool_size, 5)
  """
  @spec put(config_map(), config_key(), config_value()) :: config_map()
  def put(config, key, value) do
    Map.put(config, key, value)
  end

  @doc """
  Merges two configuration maps.

  ## Parameters

  - `base_config` - Base configuration map
  - `override_config` - Configuration map to merge in

  ## Returns

  Merged configuration map.

  ## Examples

      base = FLAME.AppleContainers.Config.load()
      overrides = %{pool_size: 8, image: "new-worker:latest"}
      merged = FLAME.AppleContainers.Config.merge(base, overrides)
  """
  @spec merge(config_map(), config_map()) :: config_map()
  def merge(base_config, override_config) do
    Map.merge(base_config, override_config)
  end

  @doc """
  Converts configuration to a format suitable for a specific component.

  ## Parameters

  - `config` - Full configuration map
  - `component` - Component to extract configuration for

  ## Returns

  Configuration map or keyword list suitable for the component.

  ## Examples

      config = FLAME.AppleContainers.Config.load()
      manager_config = FLAME.AppleContainers.Config.for_component(config, :manager)
      pool_config = FLAME.AppleContainers.Config.for_component(config, :pool)
  """
  @spec for_component(config_map(), atom()) :: config_opts() | config_map()
  def for_component(config, component) do
    case component do
      :manager ->
        [
          image: config.image,
          pool_size: config.pool_size,
          max_pool_size: config.max_pool_size,
          dns_domain: config.dns_domain,
          container_prefix: config.container_prefix,
          erlang_cookie: config.erlang_cookie,
          health_check_interval: config.health_check_interval,
          task_timeout: config.task_timeout,
          retry_attempts: config.retry_attempts,
          retry_backoff: config.retry_backoff,
          resource_limits: config.resource_limits
        ]

      :pool ->
        [
          size: config.pool_size,
          max_size: config.max_pool_size,
          min_size: config.min_pool_size,
          health_check_interval: config.health_check_interval,
          resource_limits: config.resource_limits,
          auto_scale: config.auto_scale,
          scale_up_threshold: config.scale_up_threshold,
          scale_down_threshold: config.scale_down_threshold,
          scale_cooldown: config.scale_cooldown
        ]

      :monitor ->
        [
          health_check_interval: config.health_check_interval,
          metrics_collection_interval: config.metrics_collection_interval,
          alert_thresholds: config.alert_thresholds,
          recovery_enabled: config.enable_recovery,
          notifications_enabled: config.enable_monitoring
        ]

      :backend ->
        [
          image: config.image,
          dns_domain: config.dns_domain,
          container_prefix: config.container_prefix,
          erlang_cookie: config.erlang_cookie,
          mode: config.mode
        ]

      _ ->
        Logger.warning("Unknown component: #{component}, returning full config")
        config
    end
  end

  ## Private Helper Functions

  defp merge_application_config(base_config) do
    app_config = Application.get_all_env(:flame_apple_container_backend)

    # Filter only known configuration keys
    known_keys = Map.keys(base_config)
    app_config = Enum.filter(app_config, fn {key, _value} -> key in known_keys end)

    Map.merge(base_config, Map.new(app_config))
  end

  defp merge_environment_variables(config) do
    Enum.reduce(@env_var_mappings, config, fn {env_var, config_key}, acc ->
      case System.get_env(env_var) do
        nil -> acc
        value -> Map.put(acc, config_key, parse_env_value(value))
      end
    end)
  end

  defp parse_env_value(value) do
    cond do
      value in ["true", "TRUE"] -> true
      value in ["false", "FALSE"] -> false
      String.match?(value, ~r/^\d+$/) -> String.to_integer(value)
      String.match?(value, ~r/^\d+\.\d+$/) -> String.to_float(value)
      true -> value
    end
  end

  defp merge_overrides(config, overrides) do
    override_map = Enum.into(overrides, %{})
    Map.merge(config, override_map)
  end

  defp ensure_required_values(config) do
    config = ensure_erlang_cookie(config)

    # Ensure other required derived values
    config
  end

  defp ensure_erlang_cookie(config) do
    case config.erlang_cookie do
      nil ->
        # Generate a secure random cookie
        cookie =
          :crypto.strong_rand_bytes(32)
          |> Base.encode64()
          |> String.slice(0, 20)

        Map.put(config, :erlang_cookie, cookie)

      cookie when is_binary(cookie) ->
        config

      _ ->
        Logger.error("Invalid erlang_cookie type, must be string or nil")
        Map.put(config, :erlang_cookie, nil)
    end
  end

  defp normalize_config(config) do
    config
    |> normalize_log_level()
    |> normalize_mode()
    |> normalize_timeouts()
  end

  defp normalize_log_level(config) do
    case config.log_level do
      level when level in [:debug, :info, :warning, :error] -> config
      level when is_binary(level) -> Map.put(config, :log_level, String.to_atom(level))
      _ -> Map.put(config, :log_level, :info)
    end
  end

  defp normalize_mode(config) do
    case config.mode do
      mode when mode in [:production, :development, :test] -> config
      mode when is_binary(mode) -> Map.put(config, :mode, String.to_atom(mode))
      _ -> Map.put(config, :mode, :production)
    end
  end

  defp normalize_timeouts(config) do
    config
    |> ensure_positive_timeout(:task_timeout, 300_000)
    |> ensure_positive_timeout(:health_check_interval, 30_000)
    |> ensure_positive_timeout(:metrics_collection_interval, 60_000)
    |> ensure_positive_timeout(:retry_backoff, 1000)
    |> ensure_positive_timeout(:scale_cooldown, 60_000)
  end

  defp ensure_positive_timeout(config, key, default) do
    case Map.get(config, key) do
      value when is_integer(value) and value > 0 -> config
      _ -> Map.put(config, key, default)
    end
  end

  defp validate_required_keys(config) do
    missing_keys =
      Enum.filter(@required_keys, fn key ->
        not Map.has_key?(config, key) or is_nil(Map.get(config, key))
      end)

    case missing_keys do
      [] -> :ok
      keys -> {:error, {:missing_required_keys, keys}}
    end
  end

  defp validate_pool_configuration(config) do
    cond do
      config.pool_size < 0 ->
        {:error, {:invalid_pool_size, "pool_size must be >= 0"}}

      config.max_pool_size < config.pool_size ->
        {:error, {:invalid_pool_size, "max_pool_size must be >= pool_size"}}

      config.min_pool_size < 0 ->
        {:error, {:invalid_pool_size, "min_pool_size must be >= 0"}}

      config.min_pool_size > config.pool_size ->
        {:error, {:invalid_pool_size, "min_pool_size must be <= pool_size"}}

      true ->
        :ok
    end
  end

  defp validate_resource_limits(config) do
    case config.resource_limits do
      %{memory: memory, cpu: cpu} when is_binary(memory) and is_binary(cpu) ->
        :ok

      limits when is_map(limits) ->
        # Allow other formats for flexibility
        :ok

      _ ->
        {:error, {:invalid_resource_limits, "resource_limits must be a map"}}
    end
  end

  defp validate_timeouts(config) do
    timeout_keys = [
      :task_timeout,
      :health_check_interval,
      :metrics_collection_interval,
      :retry_backoff
    ]

    invalid_timeouts =
      Enum.filter(timeout_keys, fn key ->
        case Map.get(config, key) do
          value when is_integer(value) and value > 0 -> false
          _ -> true
        end
      end)

    case invalid_timeouts do
      [] -> :ok
      keys -> {:error, {:invalid_timeouts, "Invalid timeout values for keys: #{inspect(keys)}"}}
    end
  end

  defp validate_thresholds(config) do
    case config.alert_thresholds do
      thresholds when is_map(thresholds) ->
        # Validate that numeric thresholds are reasonable
        invalid_thresholds =
          Enum.filter(thresholds, fn {key, value} ->
            case {key, value} do
              {:cpu_usage, val} when is_number(val) and val >= 0 and val <= 100 -> false
              {:memory_usage, val} when is_number(val) and val >= 0 and val <= 100 -> false
              {:error_rate, val} when is_number(val) and val >= 0 and val <= 100 -> false
              {:response_time, val} when is_number(val) and val > 0 -> false
              {:unhealthy_containers, val} when is_number(val) and val >= 0 and val <= 1 -> false
              _ -> true
            end
          end)

        case invalid_thresholds do
          [] ->
            :ok

          thresholds ->
            {:error, {:invalid_thresholds, "Invalid threshold values: #{inspect(thresholds)}"}}
        end

      _ ->
        {:error, {:invalid_thresholds, "alert_thresholds must be a map"}}
    end
  end
end
