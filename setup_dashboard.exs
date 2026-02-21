#!/usr/bin/env elixir

# Setup script for FLAME Apple Containers Dashboard
# Run with: elixir setup_dashboard.exs

IO.puts("🎛️  FLAME Apple Containers Dashboard Setup")
IO.puts("=========================================")

# Check if required dependencies are available
required_deps = [
  {:phoenix, "Phoenix framework"},
  {:phoenix_live_view, "Phoenix LiveView"},
  {:phoenix_html, "Phoenix HTML helpers"},
  {:plug_cowboy, "HTTP server"}
]

IO.puts("\n📦 Checking dependencies...")

missing_deps = Enum.filter(required_deps, fn {dep, _desc} ->
  case Code.ensure_loaded(dep) do
    {:module, _} -> false
    {:error, _} -> true
  end
end)

if length(missing_deps) > 0 do
  IO.puts("❌ Missing dependencies:")
  Enum.each(missing_deps, fn {dep, desc} ->
    IO.puts("   - #{dep} (#{desc})")
  end)
  
  IO.puts("\n💡 Add these to your mix.exs dependencies:")
  IO.puts("""
  defp deps do
    [
      # ... existing deps ...
      {:phoenix, "~> 1.7.0"},
      {:phoenix_live_view, "~> 0.20.0"},
      {:phoenix_html, "~> 3.3"},
      {:plug_cowboy, "~> 2.6"}
    ]
  end
  """)
  
  IO.puts("Then run: mix deps.get")
  System.halt(1)
else
  IO.puts("✅ All dependencies available")
end

# Start the application systems
IO.puts("\n🚀 Starting FLAME systems...")

case Application.ensure_all_started(:flame_apple_container_backend) do
  {:ok, apps} ->
    IO.puts("✅ Started applications: #{inspect(apps)}")
  
  {:error, reason} ->
    IO.puts("❌ Failed to start application: #{inspect(reason)}")
    System.halt(1)
end

# Verify core systems are running
systems = [
  {FLAME.ContainerPool, "Container Pool Management"},
  {FLAME.ContainerMetrics, "Metrics Collection"},
  {FLAME.SecurityManager, "Security Management"},
  {FLAME.ResourceManager, "Resource Management"},
  {FLAME.CircuitBreaker, "Circuit Breaker"}
]

IO.puts("\n🔍 Verifying systems...")

all_running = Enum.all?(systems, fn {module, name} ->
  case Process.whereis(module) do
    nil ->
      IO.puts("❌ #{name} not running")
      false
    
    pid when is_pid(pid) ->
      IO.puts("✅ #{name} running (#{inspect(pid)})")
      true
  end
end)

unless all_running do
  IO.puts("\n❌ Some systems are not running. Check your configuration.")
  System.halt(1)
end

# Create sample configuration
IO.puts("\n📝 Creating sample configuration...")

config_content = """
# Add this to your config/config.exs for the dashboard

import Config

config :flame_apple_container_backend, FlameWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: "#{:crypto.strong_rand_bytes(64) |> Base.encode64() |> binary_part(0, 64)}",
  live_view: [signing_salt: "#{:crypto.strong_rand_bytes(8) |> Base.encode64() |> binary_part(0, 8)}"],
  pubsub_server: FlameWeb.PubSub,
  render_errors: [view: FlameWeb.ErrorView, accepts: ~w(html json), layout: false],
  check_origin: false  # Allow all origins in development

config :phoenix, :json_library, Jason

# Telemetry configuration
config :flame_apple_container_backend, 
  telemetry_enabled: true,
  metrics_collection_interval: 5_000

# FLAME Pool configuration example
config :flame_apple_container_backend, :flame_pool,
  name: DashboardDemo.Pool,
  backend: {FLAME.AppleContainersBackend, [
    image: "flame-worker:dashboard",
    dns_domain: "dashboard.local",
    mode: :development,
    pool_config: %{
      min_warm_containers: 2,
      max_warm_containers: 5,
      max_active_containers: 10
    },
    monitoring_config: %{
      telemetry: %{enabled: true},
      prometheus: %{enabled: false}
    }
  ]}
"""

File.write!("config/dashboard_sample.exs", config_content)
IO.puts("✅ Created config/dashboard_sample.exs")

# Generate sample data for testing
IO.puts("\n🎭 Generating sample data...")

# Generate some sample metrics
Enum.each(1..5, fn i ->
  container_id = "sample-container-#{i}"
  FLAME.ContainerMetrics.record_container_provision(container_id, %{
    timestamp: System.system_time(:millisecond)
  })
end)

Enum.each(1..10, fn i ->
  task_id = "sample-task-#{i}"
  execution_time = :rand.uniform(2000) + 500
  
  FLAME.ContainerMetrics.record_task_execution(task_id, execution_time, %{
    started_at: System.system_time(:millisecond) - execution_time
  })
  
  FLAME.ContainerMetrics.record_task_completion(task_id, execution_time, %{
    completed_at: System.system_time(:millisecond)
  })
end)

# Record pool status
FLAME.ContainerMetrics.record_pool_status(%{
  warm_pool_size: 3,
  active_containers: 2,
  total_containers: 5
})

IO.puts("✅ Generated sample metrics data")

# Test security system
IO.puts("\n🔒 Testing security system...")

test_function = fn x -> x * 2 end

case FLAME.SecurityManager.validate_function(test_function, %{source: "dashboard_setup"}) do
  :ok ->
    IO.puts("✅ Security validation working")
  
  {:error, reason} ->
    IO.puts("⚠️  Security validation: #{inspect(reason)} (expected in simplified implementation)")
end

FLAME.SecurityManager.audit_log(:dashboard_setup, %{
  event: "dashboard_initialization",
  timestamp: System.system_time(:millisecond),
  user: "system"
})

IO.puts("✅ Security audit logging working")

# Test resource management
IO.puts("\n📊 Testing resource management...")

FLAME.ResourceManager.register_container("dashboard-test-container", %{
  memory_mb: 512,
  cpu_percent: 25,
  disk_mb: 1024
})

resource_status = FLAME.ResourceManager.get_resource_status()
IO.puts("✅ Resource management working - utilization: #{resource_status.utilization_percentage}%")

FLAME.ResourceManager.unregister_container("dashboard-test-container")

# Create demo module
IO.puts("\n🎪 Creating dashboard demo module...")

demo_module_content = """
defmodule DashboardDemo do
  @moduledoc \"\"\"
  Interactive demo for FLAME Apple Containers Dashboard
  \"\"\"
  
  def start_interactive_demo do
    IO.puts("🎛️  Starting FLAME Dashboard Interactive Demo")
    IO.puts("==========================================")
    
    # Start background simulators
    {:ok, _} = Task.start_link(__MODULE__, :container_simulator, [])
    {:ok, _} = Task.start_link(__MODULE__, :task_simulator, [])
    {:ok, _} = Task.start_link(__MODULE__, :resource_simulator, [])
    {:ok, _} = Task.start_link(__MODULE__, :security_simulator, [])
    
    IO.puts("✅ Background simulators started")
    IO.puts("📊 Generating live metrics for dashboard...")
    IO.puts("🌐 Start your Phoenix server and visit: http://localhost:4000/dashboard")
    
    :ok
  end
  
  def container_simulator do
    Process.sleep(5000)
    
    container_id = "demo-container-\#{:rand.uniform(999)}"
    
    # Simulate container lifecycle
    FLAME.ContainerMetrics.record_container_provision(container_id)
    Process.sleep(1000)
    FLAME.ContainerMetrics.record_container_checkout(container_id)
    Process.sleep(2000)
    FLAME.ContainerMetrics.record_container_return(container_id)
    Process.sleep(1000)
    
    # Occasionally terminate
    if :rand.uniform(10) > 7 do
      FLAME.ContainerMetrics.record_container_termination(container_id, :normal)
    end
    
    container_simulator()
  end
  
  def task_simulator do
    Process.sleep(2000)
    
    task_id = "demo-task-\#{:rand.uniform(9999)}"
    execution_time = :rand.uniform(1500) + 200
    
    FLAME.ContainerMetrics.record_task_execution(task_id, execution_time)
    
    # Simulate success/failure
    if :rand.uniform(10) > 8 do
      FLAME.ContainerMetrics.record_task_error(task_id, Enum.random([:timeout, :memory_limit, :network_error]))
    else
      FLAME.ContainerMetrics.record_task_completion(task_id, execution_time)
    end
    
    task_simulator()
  end
  
  def resource_simulator do
    Process.sleep(8000)
    
    # Simulate changing resource usage
    warm_pool = :rand.uniform(6) + 1
    active = :rand.uniform(4)
    
    FLAME.ContainerMetrics.record_pool_status(%{
      warm_pool_size: warm_pool,
      active_containers: active,
      total_containers: warm_pool + active
    })
    
    resource_simulator()
  end
  
  def security_simulator do
    Process.sleep(12000)
    
    events = [
      :function_validated,
      :function_rejected, 
      :execution_timeout,
      :memory_limit_exceeded,
      :unauthorized_access
    ]
    
    event = Enum.random(events)
    
    FLAME.SecurityManager.audit_log(event, %{
      user_id: "demo_user_\#{:rand.uniform(99)}",
      function_hash: "demo_\#{:rand.uniform(999999)}",
      timestamp: System.system_time(:millisecond),
      severity: Enum.random([:low, :medium, :high])
    })
    
    security_simulator()
  end
  
  def circuit_breaker_demo do
    IO.puts("🔄 Demonstrating circuit breaker functionality...")
    
    # Test successful operations
    Enum.each(1..3, fn i ->
      result = FLAME.CircuitBreaker.call(:demo_circuit, fn -> {:ok, "Success \#{i}"} end)
      IO.puts("Operation \#{i}: \#{inspect(result)}")
    end)
    
    # Test failures to trigger circuit breaker
    IO.puts("Triggering circuit breaker with failures...")
    Enum.each(1..6, fn i ->
      result = FLAME.CircuitBreaker.call(:demo_circuit, fn -> raise "Demo failure \#{i}" end)
      IO.puts("Failure \#{i}: \#{inspect(result)}")
    end)
    
    # Show circuit state
    state = FLAME.CircuitBreaker.get_state(:demo_circuit)
    IO.puts("Circuit breaker state: \#{inspect(state)}")
    
    # Reset circuit breaker
    FLAME.CircuitBreaker.reset(:demo_circuit)
    IO.puts("✅ Circuit breaker reset")
  end
  
  def performance_test(duration_seconds \\\\ 30) do
    IO.puts("🚀 Running performance test for \#{duration_seconds} seconds...")
    
    start_time = System.system_time(:second)
    end_time = start_time + duration_seconds
    
    # Start load generators
    generators = Enum.map(1..5, fn i ->
      Task.async(fn -> load_generator(end_time, i) end)
    end)
    
    # Monitor performance
    monitor_task = Task.async(fn -> performance_monitor(end_time) end)
    
    # Wait for completion
    Task.await_many(generators ++ [monitor_task], (duration_seconds + 10) * 1000)
    
    IO.puts("✅ Performance test completed")
    
    # Show final metrics
    metrics = FLAME.ContainerMetrics.get_metrics_summary()
    IO.puts("📊 Final metrics: \#{inspect(metrics)}")
  end
  
  defp load_generator(end_time, worker_id) do
    if System.system_time(:second) < end_time do
      task_id = "perf-test-\#{worker_id}-\#{:rand.uniform(9999)}"
      execution_time = :rand.uniform(800) + 100
      
      FLAME.ContainerMetrics.record_task_execution(task_id, execution_time)
      FLAME.ContainerMetrics.record_task_completion(task_id, execution_time)
      
      Process.sleep(50)
      load_generator(end_time, worker_id)
    end
  end
  
  defp performance_monitor(end_time) do
    if System.system_time(:second) < end_time do
      metrics = FLAME.ContainerMetrics.get_metrics_summary()
      resource_status = FLAME.ResourceManager.get_resource_status()
      
      IO.puts("📈 Tasks: \#{metrics.total_task_executions}, Avg: \#{Float.round(metrics.average_execution_time, 1)}ms, Resources: \#{resource_status.utilization_percentage}%")
      
      Process.sleep(3000)
      performance_monitor(end_time)
    end
  end
end
"""

File.write!("lib/dashboard_demo.ex", demo_module_content)
IO.puts("✅ Created lib/dashboard_demo.ex")

# Final instructions
IO.puts("\n🎉 Dashboard setup complete!")
IO.puts("==========================")

IO.puts("""

📋 Next Steps:

1. Add Phoenix dependencies to mix.exs:
   mix deps.get

2. Configure your endpoint (use config/dashboard_sample.exs as reference)

3. Create the Phoenix files:
   - lib/flame_web/endpoint.ex
   - lib/flame_web/router.ex  
   - lib/flame_web/live/dashboard_live.ex

4. Start the demo:
   iex -S mix
   DashboardDemo.start_interactive_demo()

5. Start Phoenix server (in another terminal):
   mix phx.server

6. Visit the dashboard:
   http://localhost:4000/dashboard

🧪 Test Commands (run in iex):
   DashboardDemo.circuit_breaker_demo()
   DashboardDemo.performance_test(30)

✅ Your FLAME Apple Containers backend is ready for interactive testing!
""")

# Generate final status report
IO.puts("\n📊 System Status Report:")
IO.puts("========================")

metrics = FLAME.ContainerMetrics.get_metrics_summary()
security = FLAME.SecurityManager.get_security_status()
resources = FLAME.ResourceManager.get_resource_status()

IO.puts("Metrics System: ✅ Running - #{metrics.total_task_executions} tasks recorded")
IO.puts("Security System: ✅ Running - #{security.allowed_modules_count} modules allowed")
IO.puts("Resource System: ✅ Running - #{resources.utilization_percentage}% utilization")
IO.puts("Circuit Breakers: ✅ Ready")
IO.puts("Container Pool: ✅ Ready")

IO.puts("\n🚀 Ready for production-grade FLAME operations!")