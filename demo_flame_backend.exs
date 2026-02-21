#!/usr/bin/env elixir

# Demo script for FLAME Apple Containers Backend
# Run with: elixir demo_flame_backend.exs

defmodule FLAMEDemo do
  @moduledoc """
  Interactive demo showing FLAME Apple Containers backend capabilities.
  
  This demo:
  1. Starts the FLAME backend with configurable features
  2. Demonstrates job execution with real monitoring
  3. Shows metrics, security, and resource management
  4. Optionally opens web dashboard
  """
  
  def run_interactive_demo do
    IO.puts("🔥 FLAME Apple Containers Backend - Interactive Demo")
    IO.puts("==================================================")
    
    # Get user preferences
    config = get_demo_configuration()
    
    # Start systems
    IO.puts("\n🚀 Starting FLAME systems...")
    {:ok, _apps} = start_demo_systems(config)
    
    try do
      # Run demo workflow
      run_demo_workflow(config)
    after
      # Cleanup
      cleanup_demo()
    end
    
    IO.puts("\n✅ Demo completed successfully!")
  end
  
  defp get_demo_configuration do
    IO.puts("\n🔧 Demo Configuration:")
    IO.puts("======================")
    
    web_enabled = prompt_yes_no("Enable web dashboard?", true)
    full_features = prompt_yes_no("Enable all production features?", true)
    
    config = %{
      web_interface: web_enabled,
      metrics: true,
      security: full_features,
      resource_management: full_features,
      orchestration: full_features,
      optimization: full_features,
      auto_open_browser: web_enabled && prompt_yes_no("Auto-open browser?", true)
    }
    
    IO.puts("\n📋 Configuration selected:")
    Enum.each(config, fn {key, value} ->
      status = if value, do: "✅ ENABLED", else: "❌ DISABLED"
      IO.puts("   #{String.capitalize(to_string(key))}: #{status}")
    end)
    
    config
  end
  
  defp start_demo_systems(config) do
    # Configure environment
    configure_demo_environment(config)
    
    # Start application
    case Application.ensure_all_started(:flame_apple_container_backend) do
      {:ok, apps} ->
        IO.puts("✅ Started applications: #{inspect(apps)}")
        
        # Start web interface if enabled
        if config.web_interface do
          start_web_interface()
        end
        
        {:ok, apps}
      
      {:error, reason} ->
        IO.puts("❌ Failed to start: #{inspect(reason)}")
        System.halt(1)
    end
  end
  
  defp configure_demo_environment(config) do
    # Set environment variables
    System.put_env("FLAME_ENVIRONMENT", "development")
    System.put_env("FLAME_ENABLE_WEB_INTERFACE", to_string(config.web_interface))
    System.put_env("FLAME_ENABLE_METRICS", to_string(config.metrics))
    System.put_env("FLAME_ENABLE_SECURITY", to_string(config.security))
    System.put_env("FLAME_ENABLE_RESOURCE_MANAGEMENT", to_string(config.resource_management))
    System.put_env("FLAME_ENABLE_ORCHESTRATION", to_string(config.orchestration))
    System.put_env("FLAME_ENABLE_OPTIMIZATION", to_string(config.optimization))
    
    # Configure application
    Application.put_env(:flame_apple_container_backend, :environment, :development)
    Application.put_env(:flame_apple_container_backend, :enable_web_interface, config.web_interface)
    Application.put_env(:flame_apple_container_backend, :enable_metrics, config.metrics)
    Application.put_env(:flame_apple_container_backend, :enable_security, config.security)
    Application.put_env(:flame_apple_container_backend, :enable_resource_management, config.resource_management)
    Application.put_env(:flame_apple_container_backend, :enable_orchestration, config.orchestration)
    Application.put_env(:flame_apple_container_backend, :enable_optimization, config.optimization)
  end
  
  defp start_web_interface do
    if Code.ensure_loaded?(FlameWeb.Endpoint) do
      # Configure endpoint
      Application.put_env(:flame_apple_container_backend, FlameWeb.Endpoint, [
        http: [ip: {127, 0, 0, 1}, port: 4000],
        secret_key_base: generate_secret_key(),
        live_view: [signing_salt: generate_salt()],
        check_origin: false
      ])
      
      case FlameWeb.Endpoint.start_link() do
        {:ok, _pid} ->
          IO.puts("✅ Web dashboard started at http://localhost:4000/dashboard")
        
        {:error, {:already_started, _}} ->
          IO.puts("✅ Web dashboard already running")
        
        {:error, reason} ->
          IO.puts("❌ Failed to start web dashboard: #{inspect(reason)}")
      end
    else
      IO.puts("⚠️ Web dashboard not available (Phoenix not installed)")
    end
  end
  
  defp run_demo_workflow(config) do
    IO.puts("\n🎭 Running Demo Workflow:")
    IO.puts("=========================")
    
    # Show initial status
    show_system_status()
    
    # Open browser if requested
    if config.auto_open_browser do
      open_dashboard_browser()
    end
    
    # Interactive menu
    run_interactive_menu(config)
  end
  
  defp show_system_status do
    IO.puts("\n📊 System Status:")
    
    systems = [
      {FLAME.ContainerPool, "Container Pool"},
      {FLAME.ContainerMetrics, "Metrics Collection"},
      {FLAME.SecurityManager, "Security Manager"},
      {FLAME.ResourceManager, "Resource Manager"},
      {FLAME.Orchestrator, "Orchestrator"},
      {FLAME.FunctionOptimizer, "Function Optimizer"}
    ]
    
    Enum.each(systems, fn {module, name} ->
      status = case Process.whereis(module) do
        nil -> "❌ Not Running"
        _pid -> "✅ Running"
      end
      IO.puts("   #{name}: #{status}")
    end)
    
    # Show metrics if available
    try do
      metrics = FLAME.ContainerMetrics.get_metrics_summary()
      IO.puts("   📈 Tasks Executed: #{metrics.total_task_executions}")
    rescue
      _ -> IO.puts("   📈 Metrics: Not available")
    end
  end
  
  defp open_dashboard_browser do
    IO.puts("\n🌐 Opening dashboard in browser...")
    
    url = "http://localhost:4000/dashboard"
    
    case open_browser(url) do
      :ok ->
        IO.puts("✅ Dashboard opened: #{url}")
      
      {:error, _} ->
        IO.puts("⚠️ Please manually open: #{url}")
    end
  end
  
  defp run_interactive_menu(config) do
    menu_options = [
      {"1", "Execute Simple Jobs", &execute_simple_jobs/0},
      {"2", "Execute Complex Jobs", &execute_complex_jobs/0},
      {"3", "Demonstrate Circuit Breaker", &demo_circuit_breaker/0},
      {"4", "Show Resource Management", &demo_resource_management/0},
      {"5", "Test Security Features", &demo_security_features/0},
      {"6", "Performance Benchmark", &demo_performance_benchmark/0},
      {"7", "Generate Live Metrics", &start_metrics_generator/0},
      {"8", "Show Current Status", &show_current_status/0}
    ]
    
    if config.web_interface do
      menu_options = menu_options ++ [{"9", "Open Dashboard", &open_dashboard_browser/0}]
    end
    
    menu_options = menu_options ++ [{"q", "Quit Demo", fn -> :quit end}]
    
    loop_interactive_menu(menu_options)
  end
  
  defp loop_interactive_menu(options) do
    IO.puts("\n🎛️ Interactive Demo Menu:")
    IO.puts("=========================")
    
    Enum.each(options, fn {key, description, _} ->
      IO.puts("   #{key}. #{description}")
    end)
    
    choice = IO.gets("\nSelect option: ") |> String.trim()
    
    case Enum.find(options, fn {key, _, _} -> key == choice end) do
      {_, _, :quit} ->
        IO.puts("Exiting demo...")
        :quit
      
      {_, _, func} when is_function(func) ->
        try do
          case func.() do
            :quit -> :quit
            _ -> loop_interactive_menu(options)
          end
        rescue
          error ->
            IO.puts("❌ Error: #{Exception.message(error)}")
            loop_interactive_menu(options)
        end
      
      nil ->
        IO.puts("❌ Invalid option. Please try again.")
        loop_interactive_menu(options)
    end
  end
  
  # Demo functions
  
  defp execute_simple_jobs do
    IO.puts("\n🔄 Executing Simple Jobs...")
    
    job_count = String.to_integer(IO.gets("How many jobs? (1-10): ") |> String.trim() |> ensure_range(1, 10))
    
    Enum.each(1..job_count, fn i ->
      job_id = "simple-demo-#{i}"
      IO.puts("   Executing job #{i}/#{job_count}: #{job_id}")
      
      # Simulate job execution with metrics
      start_time = System.monotonic_time(:millisecond)
      FLAME.ContainerMetrics.record_task_execution(job_id, 0)
      
      # Simulate work
      Process.sleep(:rand.uniform(1000) + 500)
      result = %{job_id: job_id, result: "completed", data: Enum.sum(1..i*100)}
      
      execution_time = System.monotonic_time(:millisecond) - start_time
      FLAME.ContainerMetrics.record_task_completion(job_id, execution_time)
      
      IO.puts("   ✅ Job #{job_id} completed in #{execution_time}ms")
    end)
    
    IO.puts("✅ All simple jobs completed!")
  end
  
  defp execute_complex_jobs do
    IO.puts("\n⚙️ Executing Complex Jobs...")
    
    # Simulate complex processing with resource usage
    Enum.each(1..3, fn i ->
      job_id = "complex-demo-#{i}"
      container_id = "complex-container-#{i}"
      
      IO.puts("   Starting complex job #{i}: #{job_id}")
      
      # Record container provision
      FLAME.ContainerMetrics.record_container_provision(container_id)
      FLAME.ContainerMetrics.record_container_checkout(container_id)
      
      # Register resource usage
      FLAME.ResourceManager.register_container(container_id, %{
        memory_mb: 512 * i,
        cpu_percent: 30 * i,
        disk_mb: 1024
      })
      
      # Simulate longer processing
      start_time = System.monotonic_time(:millisecond)
      FLAME.ContainerMetrics.record_task_execution(job_id, 0)
      
      Process.sleep(:rand.uniform(3000) + 1000)  # 1-4 seconds
      
      execution_time = System.monotonic_time(:millisecond) - start_time
      FLAME.ContainerMetrics.record_task_completion(job_id, execution_time)
      
      # Return container
      FLAME.ContainerMetrics.record_container_return(container_id)
      FLAME.ResourceManager.unregister_container(container_id)
      
      IO.puts("   ✅ Complex job #{job_id} completed in #{execution_time}ms")
    end)
    
    IO.puts("✅ All complex jobs completed!")
  end
  
  defp demo_circuit_breaker do
    IO.puts("\n🔄 Circuit Breaker Demonstration...")
    
    circuit_name = :demo_circuit
    
    # Show initial state
    state = FLAME.CircuitBreaker.get_state(circuit_name)
    IO.puts("   Initial circuit state: #{state.state}")
    
    # Execute successful operations
    IO.puts("   Executing successful operations...")
    Enum.each(1..3, fn i ->
      result = FLAME.CircuitBreaker.call(circuit_name, fn -> {:ok, "Success #{i}"} end)
      IO.puts("     Operation #{i}: #{inspect(result)}")
    end)
    
    # Execute failing operations to trigger circuit breaker
    IO.puts("   Triggering circuit breaker with failures...")
    Enum.each(1..6, fn i ->
      result = FLAME.CircuitBreaker.call(circuit_name, fn -> raise "Demo failure #{i}" end)
      IO.puts("     Failure #{i}: #{inspect(result)}")
    end)
    
    # Show final state
    final_state = FLAME.CircuitBreaker.get_state(circuit_name)
    IO.puts("   Final circuit state: #{final_state.state} (failures: #{final_state.failure_count})")
    
    # Reset circuit
    FLAME.CircuitBreaker.reset(circuit_name)
    IO.puts("   ✅ Circuit breaker reset")
  end
  
  defp demo_resource_management do
    IO.puts("\n📊 Resource Management Demonstration...")
    
    # Show initial resource status
    initial_status = FLAME.ResourceManager.get_resource_status()
    IO.puts("   Initial resource utilization: #{initial_status.utilization_percentage}%")
    
    # Register test containers with different resource requirements
    containers = [
      {"light-container", %{memory_mb: 256, cpu_percent: 20}},
      {"medium-container", %{memory_mb: 512, cpu_percent: 50}},
      {"heavy-container", %{memory_mb: 1024, cpu_percent: 80}}
    ]
    
    IO.puts("   Registering containers with different resource requirements...")
    Enum.each(containers, fn {name, resources} ->
      FLAME.ResourceManager.register_container(name, resources)
      IO.puts("     Registered #{name}: #{resources.memory_mb}MB, #{resources.cpu_percent}% CPU")
    end)
    
    # Show updated status
    updated_status = FLAME.ResourceManager.get_resource_status()
    IO.puts("   Updated resource utilization: #{updated_status.utilization_percentage}%")
    IO.puts("   Container count: #{updated_status.container_count}")
    
    # Cleanup
    Enum.each(containers, fn {name, _} ->
      FLAME.ResourceManager.unregister_container(name)
    end)
    
    IO.puts("   ✅ Resource management demo completed")
  end
  
  defp demo_security_features do
    IO.puts("\n🔒 Security Features Demonstration...")
    
    # Test function validation
    safe_function = fn x -> x * 2 end
    dangerous_function = fn -> File.read("/etc/passwd") end
    
    IO.puts("   Testing function validation...")
    
    case FLAME.SecurityManager.validate_function(safe_function) do
      :ok -> IO.puts("     ✅ Safe function validated")
      {:error, reason} -> IO.puts("     ⚠️ Safe function rejected: #{inspect(reason)}")
    end
    
    # Test audit logging
    IO.puts("   Creating audit log entries...")
    FLAME.SecurityManager.audit_log(:demo_event, %{
      event: "security_demonstration",
      user: "demo_user",
      timestamp: System.system_time(:millisecond)
    })
    
    # Show security status
    security_status = FLAME.SecurityManager.get_security_status()
    IO.puts("   Security status:")
    IO.puts("     Sandbox enabled: #{security_status.sandbox_enabled}")
    IO.puts("     Audit enabled: #{security_status.audit_enabled}")
    IO.puts("     Allowed modules: #{security_status.allowed_modules_count}")
    
    IO.puts("   ✅ Security features demo completed")
  end
  
  defp demo_performance_benchmark do
    IO.puts("\n📈 Performance Benchmark...")
    
    task_count = String.to_integer(IO.gets("Number of concurrent tasks? (1-20): ") |> String.trim() |> ensure_range(1, 20))
    
    IO.puts("   Running #{task_count} concurrent tasks...")
    
    start_time = System.monotonic_time(:millisecond)
    
    tasks = Enum.map(1..task_count, fn i ->
      Task.async(fn ->
        job_id = "benchmark-#{i}"
        task_start = System.monotonic_time(:millisecond)
        
        # Simulate work
        Process.sleep(:rand.uniform(1000) + 200)
        result = Enum.sum(1..(i * 100))
        
        task_time = System.monotonic_time(:millisecond) - task_start
        FLAME.ContainerMetrics.record_task_execution(job_id, task_time)
        FLAME.ContainerMetrics.record_task_completion(job_id, task_time)
        
        {job_id, task_time, result}
      end)
    end)
    
    results = Task.await_many(tasks, 10_000)
    total_time = System.monotonic_time(:millisecond) - start_time
    
    # Calculate statistics
    execution_times = Enum.map(results, fn {_, time, _} -> time end)
    avg_time = Enum.sum(execution_times) / length(execution_times)
    min_time = Enum.min(execution_times)
    max_time = Enum.max(execution_times)
    
    IO.puts("   📊 Benchmark Results:")
    IO.puts("     Total time: #{total_time}ms")
    IO.puts("     Tasks completed: #{length(results)}")
    IO.puts("     Average task time: #{Float.round(avg_time, 1)}ms")
    IO.puts("     Min/Max task time: #{min_time}ms / #{max_time}ms")
    IO.puts("     Throughput: #{Float.round(length(results) / (total_time / 1000), 2)} tasks/sec")
    
    IO.puts("   ✅ Performance benchmark completed")
  end
  
  defp start_metrics_generator do
    IO.puts("\n📊 Starting Live Metrics Generator...")
    
    duration = String.to_integer(IO.gets("Run for how many seconds? (10-120): ") |> String.trim() |> ensure_range(10, 120))
    
    IO.puts("   Generating live metrics for #{duration} seconds...")
    IO.puts("   (Check the web dashboard for real-time updates)")
    
    {:ok, generator} = Task.start_link(fn ->
      generate_live_metrics(duration)
    end)
    
    # Monitor progress
    Enum.each(1..duration, fn second ->
      if rem(second, 5) == 0 do
        metrics = FLAME.ContainerMetrics.get_metrics_summary()
        IO.puts("   #{second}s: #{metrics.total_task_executions} tasks executed")
      end
      Process.sleep(1000)
    end)
    
    IO.puts("   ✅ Live metrics generation completed")
  end
  
  defp generate_live_metrics(duration) do
    end_time = System.system_time(:second) + duration
    
    generate_metrics_loop(end_time, 1)
  end
  
  defp generate_metrics_loop(end_time, counter) do
    if System.system_time(:second) < end_time do
      # Generate various types of events
      case rem(counter, 10) do
        0 -> generate_container_events()
        1 -> generate_task_events()
        2 -> generate_pool_status_update()
        3 -> generate_resource_events()
        _ -> generate_task_events()
      end
      
      Process.sleep(:rand.uniform(500) + 200)  # 200-700ms intervals
      generate_metrics_loop(end_time, counter + 1)
    end
  end
  
  defp generate_container_events do
    container_id = "live-container-#{:rand.uniform(999)}"
    FLAME.ContainerMetrics.record_container_provision(container_id)
    Process.sleep(100)
    FLAME.ContainerMetrics.record_container_checkout(container_id)
    Process.sleep(100)
    FLAME.ContainerMetrics.record_container_return(container_id)
  end
  
  defp generate_task_events do
    task_id = "live-task-#{:rand.uniform(9999)}"
    execution_time = :rand.uniform(2000) + 300
    
    FLAME.ContainerMetrics.record_task_execution(task_id, execution_time)
    
    # 90% success rate
    if :rand.uniform(10) > 9 do
      FLAME.ContainerMetrics.record_task_error(task_id, :timeout)
    else
      FLAME.ContainerMetrics.record_task_completion(task_id, execution_time)
    end
  end
  
  defp generate_pool_status_update do
    warm_pool = :rand.uniform(8) + 2
    active = :rand.uniform(5) + 1
    
    FLAME.ContainerMetrics.record_pool_status(%{
      warm_pool_size: warm_pool,
      active_containers: active,
      total_containers: warm_pool + active
    })
  end
  
  defp generate_resource_events do
    container_id = "resource-container-#{:rand.uniform(99)}"
    
    FLAME.ResourceManager.register_container(container_id, %{
      memory_mb: :rand.uniform(512) + 256,
      cpu_percent: :rand.uniform(60) + 20,
      disk_mb: :rand.uniform(1024) + 512
    })
    
    # Unregister after a delay
    spawn(fn ->
      Process.sleep(:rand.uniform(5000) + 2000)
      FLAME.ResourceManager.unregister_container(container_id)
    end)
  end
  
  defp show_current_status do
    IO.puts("\n📊 Current System Status:")
    IO.puts("=========================")
    
    # System processes
    show_system_status()
    
    # Detailed metrics
    try do
      metrics = FLAME.ContainerMetrics.get_metrics_summary()
      IO.puts("\n📈 Detailed Metrics:")
      IO.puts("   Total Tasks: #{metrics.total_task_executions}")
      IO.puts("   Avg Execution Time: #{Float.round(metrics.average_execution_time, 1)}ms")
      if metrics.pool_status do
        IO.puts("   Pool Status: Warm=#{metrics.pool_status.warm_pool_size}, Active=#{metrics.pool_status.active_containers}")
      end
    rescue
      _ -> IO.puts("   📈 Detailed metrics not available")
    end
    
    # Resource status
    try do
      resources = FLAME.ResourceManager.get_resource_status()
      IO.puts("\n🔧 Resource Status:")
      IO.puts("   Utilization: #{resources.utilization_percentage}%")
      IO.puts("   Container Count: #{resources.container_count}")
    rescue
      _ -> IO.puts("   🔧 Resource status not available")
    end
    
    IO.puts("\n✅ Status display completed")
  end
  
  # Utility functions
  
  defp prompt_yes_no(question, default) do
    default_text = if default, do: "Y/n", else: "y/N"
    response = IO.gets("#{question} (#{default_text}): ") |> String.trim() |> String.downcase()
    
    case response do
      "" -> default
      "y" -> true
      "yes" -> true
      "n" -> false
      "no" -> false
      _ -> prompt_yes_no("Please enter y or n. #{question}", default)
    end
  end
  
  defp ensure_range(input, min, max) do
    case Integer.parse(input) do
      {num, _} when num >= min and num <= max -> to_string(num)
      _ -> to_string(min)
    end
  end
  
  defp open_browser(url) do
    case :os.type() do
      {:unix, :darwin} -> System.cmd("open", [url])
      {:unix, _} -> System.cmd("xdg-open", [url])
      {:win32, _} -> System.cmd("cmd", ["/c", "start", url])
    end
    :ok
  rescue
    _ -> {:error, "Could not open browser"}
  end
  
  defp generate_secret_key do
    :crypto.strong_rand_bytes(64) |> Base.encode64() |> binary_part(0, 64)
  end
  
  defp generate_salt do
    :crypto.strong_rand_bytes(8) |> Base.encode64() |> binary_part(0, 8)
  end
  
  defp cleanup_demo do
    IO.puts("\n🧹 Cleaning up demo...")
    
    # Stop any running processes
    try do
      if Process.whereis(FlameWeb.Endpoint) do
        GenServer.stop(FlameWeb.Endpoint)
      end
    rescue
      _ -> :ok
    end
    
    IO.puts("✅ Demo cleanup completed")
  end
end

# Run the demo
FLAMEDemo.run_interactive_demo()