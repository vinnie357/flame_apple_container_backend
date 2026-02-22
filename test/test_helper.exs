# Set logger level to emergency BEFORE starting ExUnit and applications
Logger.configure(level: :emergency)
Logger.remove_backend(:console)
Application.put_env(:logger, :level, :emergency)
Application.put_env(:logger, :compile_time_purge_matching, [[level_lower_than: :emergency]])

ExUnit.start(exclude: [:integration])

# Ensure applications are started before running tests
Application.ensure_all_started(:floki)
Application.ensure_all_started(:phoenix_live_view)

# Load test support modules
Code.require_file("support/conn_case.ex", __DIR__)

# Configure test environment
Application.put_env(:flame_apple_container_backend, :environment, :test)

# Configure dashboard tier for testing
System.put_env("FLAME_DASHBOARD_TIER", "standard")

# Configure Phoenix endpoint for testing
Application.put_env(:flame_apple_container_backend, FlameWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "test_secret_key_base_for_testing_only_this_must_be_at_least_64_bytes_long_to_work_properly",
  live_view: [signing_salt: "test_salt"],
  pubsub_server: FlameWeb.PubSub,
  server: false
)

# Start floki BEFORE the main application to ensure it's available for Phoenix LiveView tests
case Application.ensure_all_started(:floki) do
  {:ok, _} -> :ok
  {:error, {:already_started, :floki}} -> :ok
  {:error, _error} -> :ok
end

# Start the application for LiveView tests (only if not already started)
case Application.ensure_all_started(:flame_apple_container_backend) do
  {:ok, _} -> :ok
  {:error, {:already_started, :flame_apple_container_backend}} -> :ok
  {:error, _error} -> :ok
end

# Start the Phoenix endpoint explicitly for LiveView tests
try do
  FlameWeb.Endpoint.start_link()
rescue
  _error -> :ok
end

# Ensure required modules are available for testing
Code.ensure_loaded(FLAME.ContainerPool)
Code.ensure_loaded(FLAME.CircuitBreaker)
Code.ensure_loaded(FLAME.ContainerMetrics)
Code.ensure_loaded(FLAME.SecurityManager)
Code.ensure_loaded(FLAME.ResourceManager)
Code.ensure_loaded(FLAME.Orchestrator)
Code.ensure_loaded(FLAME.FunctionOptimizer)

# Final verification that Floki is available for LiveView tests
case Code.ensure_loaded(Floki) do
  {:module, _} -> :ok
  {:error, _error} -> :ok
end

# Test configuration helpers
defmodule TestHelpers do
  def test_config do
    %{
      environment: :test,
      timeout_short: 1_000,
      timeout_medium: 5_000,
      timeout_long: 10_000
    }
  end

  def wait_for_async(timeout \\ 100) do
    Process.sleep(timeout)
  end

  def assert_eventually(assertion_fn, timeout \\ 1000, interval \\ 50) do
    end_time = System.monotonic_time(:millisecond) + timeout

    check_assertion(assertion_fn, end_time, interval)
  end

  defp check_assertion(assertion_fn, end_time, interval) do
    assertion_fn.()
  rescue
    ExUnit.AssertionError ->
      current_time = System.monotonic_time(:millisecond)

      if current_time < end_time do
        Process.sleep(interval)
        check_assertion(assertion_fn, end_time, interval)
      else
        # Let it fail with the assertion error
        assertion_fn.()
      end
  end
end
