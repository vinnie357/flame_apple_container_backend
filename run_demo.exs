#!/usr/bin/env elixir

# Demo script to generate FLAME activity while dashboard is running
IO.puts("🔥 Starting FLAME Activity Demo")
IO.puts("================================")

# Start application if not running
Application.ensure_all_started(:flame_apple_container_backend)

defmodule FlameActivityDemo do
  def start_simulation do
    IO.puts("🚀 Starting live FLAME job simulations...")
    
    # Simulate container provisioning
    simulate_container_activity()
    
    # Simulate task execution
    simulate_task_activity()
    
    # Simulate resource usage
    simulate_resource_activity()
    
    # Simulate security events
    simulate_security_activity()
    
    IO.puts("✅ Demo simulation started - check dashboard at http://localhost:4001/dashboard")
  end
  
  defp simulate_container_activity do
    spawn(fn -> container_simulation_loop() end)
  end
  
  defp simulate_task_activity do
    spawn(fn -> task_simulation_loop() end)
  end
  
  defp simulate_resource_activity do
    spawn(fn -> resource_simulation_loop() end)
  end
  
  defp simulate_security_activity do
    spawn(fn -> security_simulation_loop() end)
  end
  
  defp container_simulation_loop do
    container_id = "demo-container-#{:rand.uniform(9999)}"
    
    IO.puts("📦 Provisioning container: #{container_id}")
    FLAME.ContainerMetrics.record_container_provision(container_id)
    
    Process.sleep(2000)
    
    IO.puts("✅ Container checked out: #{container_id}")
    FLAME.ContainerMetrics.record_container_checkout(container_id)
    
    Process.sleep(3000)
    
    IO.puts("↩️  Container returned: #{container_id}")
    FLAME.ContainerMetrics.record_container_return(container_id)
    
    Process.sleep(5000)
    
    # Randomly terminate some containers
    if :rand.uniform(10) > 7 do
      IO.puts("🗑️  Container terminated: #{container_id}")
      FLAME.ContainerMetrics.record_container_termination(container_id, :normal)
    end
    
    Process.sleep(2000)
    container_simulation_loop()
  end
  
  defp task_simulation_loop do
    task_id = "demo-task-#{:rand.uniform(99999)}"
    execution_time = :rand.uniform(2000) + 300
    
    IO.puts("⚡ Executing task: #{task_id} (#{execution_time}ms)")
    FLAME.ContainerMetrics.record_task_execution(task_id, execution_time)
    
    Process.sleep(execution_time + 100)
    
    # Simulate success/failure
    if :rand.uniform(10) > 8 do
      error_type = Enum.random([:timeout, :memory_limit, :network_error, :function_error])
      IO.puts("❌ Task failed: #{task_id} - #{error_type}")
      FLAME.ContainerMetrics.record_task_error(task_id, error_type)
    else
      IO.puts("✅ Task completed: #{task_id}")
      FLAME.ContainerMetrics.record_task_completion(task_id, execution_time)
    end
    
    Process.sleep(:rand.uniform(1000) + 500)
    task_simulation_loop()
  end
  
  defp resource_simulation_loop do
    warm_pool = :rand.uniform(8) + 1
    active = :rand.uniform(5)
    
    pool_status = %{
      warm_pool_size: warm_pool,
      active_containers: active,
      total_containers: warm_pool + active
    }
    
    IO.puts("📊 Pool status: #{inspect(pool_status)}")
    FLAME.ContainerMetrics.record_pool_status(pool_status)
    
    Process.sleep(:rand.uniform(5000) + 3000)
    resource_simulation_loop()
  end
  
  defp security_simulation_loop do
    events = [
      :function_validated,
      :function_rejected, 
      :execution_timeout,
      :memory_limit_exceeded,
      :unauthorized_access,
      :suspicious_function,
      :rate_limit_exceeded
    ]
    
    event = Enum.random(events)
    severity = Enum.random([:low, :medium, :high])
    
    audit_data = %{
      user_id: "demo_user_#{:rand.uniform(99)}",
      function_hash: "demo_#{:rand.uniform(999999)}",
      timestamp: System.system_time(:millisecond),
      severity: severity,
      ip_address: "192.168.1.#{:rand.uniform(255)}",
      details: "Demo security event for testing"
    }
    
    IO.puts("🔒 Security event: #{event} (#{severity})")
    FLAME.SecurityManager.audit_log(event, audit_data)
    
    Process.sleep(:rand.uniform(8000) + 4000)
    security_simulation_loop()
  end
  
  def run_performance_test(duration_seconds \\ 60) do
    IO.puts("🚀 Running #{duration_seconds}s performance test...")
    
    start_time = System.system_time(:second)
    end_time = start_time + duration_seconds
    
    # Start multiple load generators
    generators = Enum.map(1..4, fn i ->
      spawn(fn -> load_generator(end_time, i) end)
    end)
    
    # Monitor progress
    monitor_pid = spawn(fn -> performance_monitor(end_time) end)
    
    IO.puts("✅ Performance test running - check dashboard for real-time metrics")
    {:ok, generators ++ [monitor_pid]}
  end
  
  defp load_generator(end_time, worker_id) do
    if System.system_time(:second) < end_time do
      task_id = "perf-test-#{worker_id}-#{:rand.uniform(9999)}"
      execution_time = :rand.uniform(800) + 100
      
      FLAME.ContainerMetrics.record_task_execution(task_id, execution_time)
      FLAME.ContainerMetrics.record_task_completion(task_id, execution_time)
      
      Process.sleep(:rand.uniform(200) + 50)
      load_generator(end_time, worker_id)
    end
  end
  
  defp performance_monitor(end_time) do
    if System.system_time(:second) < end_time do
      try do
        metrics = FLAME.ContainerMetrics.get_metrics_summary()
        resource_status = FLAME.ResourceManager.get_resource_status()
        
        IO.puts("📈 Tasks: #{metrics.total_task_executions}, Avg: #{Float.round(metrics.average_execution_time, 1)}ms, Utilization: #{resource_status.utilization_percentage}%")
      rescue
        _ -> IO.puts("📈 Monitoring active...")
      end
      
      Process.sleep(5000)
      performance_monitor(end_time)
    end
  end
end

# Start the simulation
FlameActivityDemo.start_simulation()

# Also run a performance test
{:ok, _pids} = FlameActivityDemo.run_performance_test(120)

IO.puts("""

🎯 Live Demo Running!
====================

• Dashboard: http://localhost:4001/dashboard
• Container activity simulating every 2-10 seconds
• Task execution simulating every 1-2 seconds  
• Resource monitoring every 3-8 seconds
• Security events every 4-12 seconds
• Performance test running for 2 minutes

Watch the dashboard for real-time metrics!
Press Ctrl+C to stop.
""")

# Keep script running
receive do
  :never -> :ok
end