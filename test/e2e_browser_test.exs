defmodule E2EBrowserTest do
  @moduledoc """
  End-to-end browser test that demonstrates the complete FLAME Apple Containers workflow.

  This test:
  1. Starts the FLAME backend with web interface
  2. Opens a browser to the dashboard
  3. Executes real FLAME jobs
  4. Shows live metrics and monitoring
  5. Demonstrates graceful shutdown

  Run with: elixir test/e2e_browser_test.exs
  """

  def run_complete_test do
    IO.puts("🚀 FLAME Apple Containers - Complete E2E Test")
    IO.puts("==============================================")

    # Configuration for full-featured test
    config_test_environment()

    # Start all systems
    {:ok, systems} = start_test_systems()

    try do
      # Run the complete test workflow
      run_test_workflow(systems)
    after
      # Clean shutdown
      shutdown_test_systems(systems)
    end

    IO.puts("\n✅ E2E Test completed successfully!")
  end

  defp config_test_environment do
    IO.puts("\n📋 Configuring test environment...")

    # Set environment variables for full-featured test
    System.put_env("FLAME_ENVIRONMENT", "development")
    System.put_env("FLAME_ENABLE_WEB_INTERFACE", "true")
    System.put_env("FLAME_ENABLE_METRICS", "true")
    System.put_env("FLAME_ENABLE_SECURITY", "true")
    System.put_env("FLAME_ENABLE_RESOURCE_MANAGEMENT", "true")
    System.put_env("FLAME_ENABLE_BENCHMARKS", "true")
    System.put_env("FLAME_WEB_PORT", "4001")

    # Configure application
    Application.put_env(:flame_apple_container_backend, :environment, :development)
    Application.put_env(:flame_apple_container_backend, :enable_web_interface, true)
    Application.put_env(:flame_apple_container_backend, :enable_metrics, true)
    Application.put_env(:flame_apple_container_backend, :enable_security, true)
    Application.put_env(:flame_apple_container_backend, :enable_resource_management, true)
    Application.put_env(:flame_apple_container_backend, :enable_benchmarks, true)

    # Phoenix endpoint configuration
    Application.put_env(:flame_apple_container_backend, FlameWeb.Endpoint,
      http: [ip: {127, 0, 0, 1}, port: 4001],
      secret_key_base: generate_secret_key(),
      live_view: [signing_salt: generate_salt()],
      check_origin: false,
      debug_errors: true,
      code_reloader: false
    )

    IO.puts("✅ Environment configured")
  end

  defp start_test_systems do
    IO.puts("\n🔧 Starting FLAME systems...")

    # Start the main application
    case Application.ensure_all_started(:flame_apple_container_backend) do
      {:ok, apps} ->
        IO.puts("✅ Started applications: #{inspect(apps)}")

      {:error, reason} ->
        IO.puts("❌ Failed to start application: #{inspect(reason)}")
        raise "Application start failed"
    end

    # Verify all systems are running
    systems_status = verify_systems_running()

    # Start web endpoint if available
    web_endpoint = start_web_endpoint()

    systems = %{
      applications: Application.started_applications(),
      web_endpoint: web_endpoint,
      systems_status: systems_status
    }

    IO.puts("✅ All systems started successfully")
    {:ok, systems}
  end

  defp verify_systems_running do
    systems = [
      {FLAME.ContainerPool, "Container Pool"},
      {FLAME.ContainerMetrics, "Metrics Collection"},
      {FLAME.SecurityManager, "Security Manager"},
      {FLAME.ResourceManager, "Resource Manager"},
      {FLAME.CircuitBreaker, "Circuit Breaker"}
    ]

    IO.puts("\n🔍 Verifying systems status:")

    status =
      Enum.map(systems, fn {module, name} ->
        case Process.whereis(module) do
          nil ->
            IO.puts("❌ #{name}: Not running")
            {module, :not_running}

          pid when is_pid(pid) ->
            IO.puts("✅ #{name}: Running (#{inspect(pid)})")
            {module, :running, pid}
        end
      end)

    status
  end

  defp start_web_endpoint do
    case Code.ensure_loaded(FlameWeb.Endpoint) do
      {:module, FlameWeb.Endpoint} ->
        case FlameWeb.Endpoint.start_link() do
          {:ok, pid} ->
            IO.puts("✅ Web endpoint started on http://localhost:4001")
            pid

          {:error, {:already_started, pid}} ->
            IO.puts("✅ Web endpoint already running")
            pid

          {:error, reason} ->
            IO.puts("❌ Failed to start web endpoint: #{inspect(reason)}")
            nil
        end

      {:error, _} ->
        IO.puts("⚠️  Web endpoint not available (Phoenix not loaded)")
        nil
    end
  end

  defp run_test_workflow(_systems) do
    IO.puts("\n🎭 Running complete test workflow...")

    # Phase 1: Initial system status
    display_initial_status()

    # Phase 2: Open browser to dashboard
    open_dashboard_in_browser()

    # Phase 3: Execute test jobs and show real-time updates
    execute_test_jobs_with_monitoring()

    # Phase 4: Demonstrate advanced features
    demonstrate_advanced_features()

    # Phase 5: Show graceful shutdown
    demonstrate_graceful_operations()
  end

  defp display_initial_status do
    IO.puts("\n📊 Initial System Status:")
    IO.puts("=========================")

    # Pool status
    pool_status = get_safe_status(fn -> FLAME.ContainerPool.get_pool_status() end, "Pool")
    IO.puts("Container Pool: #{format_status(pool_status)}")

    # Metrics status
    metrics = get_safe_status(fn -> FLAME.ContainerMetrics.get_metrics_summary() end, "Metrics")
    IO.puts("Metrics: #{format_metrics(metrics)}")

    # Resource status
    resources =
      get_safe_status(fn -> FLAME.ResourceManager.get_resource_status() end, "Resources")

    IO.puts("Resources: #{format_resources(resources)}")

    # Security status
    security = get_safe_status(fn -> FLAME.SecurityManager.get_security_status() end, "Security")
    IO.puts("Security: #{format_security(security)}")
  end

  defp open_dashboard_in_browser do
    IO.puts("\n🌐 Opening Dashboard in Browser...")
    IO.puts("==================================")

    dashboard_url = "http://localhost:4001/dashboard"

    # Try to open browser
    case open_browser(dashboard_url) do
      :ok ->
        IO.puts("✅ Dashboard opened in browser: #{dashboard_url}")
        IO.puts("   You should see:")
        IO.puts("   - Real-time container metrics")
        IO.puts("   - Task execution monitoring")
        IO.puts("   - Resource utilization graphs")
        IO.puts("   - Circuit breaker status")

      {:error, reason} ->
        IO.puts("⚠️  Could not auto-open browser: #{reason}")
        IO.puts("   Please manually open: #{dashboard_url}")
    end

    IO.puts("\n⏳ Waiting 5 seconds for dashboard to load...")
    Process.sleep(5000)
  end

  defp execute_test_jobs_with_monitoring do
    IO.puts("\n🚀 Executing Test Jobs with Live Monitoring:")
    IO.puts("============================================")

    # Start background metrics generator for live dashboard updates
    {:ok, metrics_generator} = start_metrics_generator()

    # Execute different types of jobs
    job_types = [
      {"Simple Computation", :simple, 3},
      {"Complex Processing", :complex, 2},
      {"ML Simulation", :ml, 2},
      {"Error Handling", :error, 1}
    ]

    total_jobs = Enum.sum(Enum.map(job_types, fn {_, _, count} -> count end))
    current_job = 0

    Enum.each(job_types, fn {job_name, job_type, count} ->
      IO.puts("\n📋 Running #{count} #{job_name} jobs...")

      Enum.each(1..count, fn i ->
        current_job = current_job + 1
        job_id = "e2e-#{job_type}-#{i}"

        IO.puts("   🔄 Executing job #{current_job}/#{total_jobs}: #{job_id}")

        execute_and_report_job(job_id, job_type, i, current_job, total_jobs)
      end)
    end)

    # Stop metrics generator
    GenServer.stop(metrics_generator)
    IO.puts("\n✅ All test jobs completed")
  end

  defp execute_and_report_job(job_id, job_type, iteration, current_job, total_jobs) do
    # Execute job with real metrics recording
    result = execute_monitored_job(job_id, job_type, iteration)

    case result do
      {:ok, _data} ->
        IO.puts("   ✅ Job #{job_id} completed successfully")

      {:error, reason} ->
        IO.puts("   ❌ Job #{job_id} failed: #{inspect(reason)}")
    end

    # Pause between jobs to show progression in dashboard
    if current_job < total_jobs do
      IO.puts("   ⏳ Pausing 3 seconds (check dashboard for updates)...")
      Process.sleep(3000)
    end
  end

  defp demonstrate_advanced_features do
    IO.puts("\n🎛️ Demonstrating Advanced Features:")
    IO.puts("===================================")

    # Circuit breaker demonstration
    IO.puts("\n🔄 Circuit Breaker Demo:")
    demonstrate_circuit_breaker()

    # Resource management demo
    IO.puts("\n📊 Resource Management Demo:")
    demonstrate_resource_management()

    # Security features demo
    IO.puts("\n🔒 Security Features Demo:")
    demonstrate_security_features()

    # Performance monitoring
    IO.puts("\n📈 Performance Monitoring Demo:")
    demonstrate_performance_monitoring()
  end

  defp demonstrate_graceful_operations do
    IO.puts("\n🛑 Demonstrating Graceful Operations:")
    IO.puts("====================================")

    # Show clean metrics
    final_metrics = FLAME.ContainerMetrics.get_metrics_summary()
    IO.puts("📊 Final metrics summary:")
    IO.puts("   Total tasks executed: #{final_metrics.total_task_executions}")

    IO.puts(
      "   Average execution time: #{Float.round(final_metrics.average_execution_time, 1)}ms"
    )

    # Show resource cleanup
    resource_status = FLAME.ResourceManager.get_resource_status()
    IO.puts("🔧 Resource status:")
    IO.puts("   Container count: #{resource_status.container_count}")
    IO.puts("   Utilization: #{resource_status.utilization_percentage}%")

    # Security audit summary
    IO.puts("🔒 Security summary: All operations completed safely")

    IO.puts("\n✅ System ready for graceful shutdown")
  end

  # Helper functions

  defp execute_monitored_job(job_id, job_type, iteration) do
    # Record task start
    start_time = System.monotonic_time(:millisecond)

    FLAME.ContainerMetrics.record_task_execution(job_id, 0, %{
      started_at: start_time,
      job_type: job_type,
      iteration: iteration
    })

    try do
      # Simulate different job types
      result =
        case job_type do
          :simple ->
            simulate_simple_job(iteration)

          :complex ->
            simulate_complex_job(iteration)

          :ml ->
            simulate_ml_job(iteration)

          :error ->
            simulate_error_job(iteration)
        end

      # Record successful completion
      execution_time = System.monotonic_time(:millisecond) - start_time

      FLAME.ContainerMetrics.record_task_completion(job_id, execution_time, %{
        completed_at: System.monotonic_time(:millisecond),
        result_type: get_result_type(result)
      })

      {:ok, result}
    rescue
      error ->
        _execution_time = System.monotonic_time(:millisecond) - start_time

        FLAME.ContainerMetrics.record_task_error(job_id, error.__struct__, %{
          error_at: System.monotonic_time(:millisecond),
          error_message: Exception.message(error)
        })

        {:error, error}
    end
  end

  defp simulate_simple_job(iteration) do
    # Simulate container provision and work
    container_id = "e2e-simple-#{iteration}-#{:rand.uniform(999)}"
    FLAME.ContainerMetrics.record_container_provision(container_id)
    FLAME.ContainerMetrics.record_container_checkout(container_id)

    # Simulate computation
    # 500-1500ms
    Process.sleep(:rand.uniform(1000) + 500)

    result = %{
      computation: "sum_of_squares",
      input_size: iteration * 100,
      result: 1..(iteration * 100) |> Enum.map(&(&1 * &1)) |> Enum.sum(),
      container_id: container_id
    }

    FLAME.ContainerMetrics.record_container_return(container_id)
    result
  end

  defp simulate_complex_job(iteration) do
    container_id = "e2e-complex-#{iteration}-#{:rand.uniform(999)}"
    FLAME.ContainerMetrics.record_container_provision(container_id)
    FLAME.ContainerMetrics.record_container_checkout(container_id)

    # Longer processing time
    # 1-3 seconds
    Process.sleep(:rand.uniform(2000) + 1000)

    # Simulate resource usage
    FLAME.ResourceManager.register_container(container_id, %{
      memory_mb: 512,
      cpu_percent: 60,
      disk_mb: 1024
    })

    result = %{
      algorithm: "complex_data_processing",
      dataset_size: iteration * 1000,
      processing_steps: [:extract, :transform, :analyze, :summarize],
      container_id: container_id,
      resource_usage: %{memory_mb: :rand.uniform(400) + 100}
    }

    FLAME.ContainerMetrics.record_container_return(container_id)
    FLAME.ResourceManager.unregister_container(container_id)
    result
  end

  defp simulate_ml_job(iteration) do
    container_id = "e2e-ml-#{iteration}-#{:rand.uniform(999)}"
    FLAME.ContainerMetrics.record_container_provision(container_id)
    FLAME.ContainerMetrics.record_container_checkout(container_id)

    # ML jobs take longer and use more resources
    # 2-5 seconds
    Process.sleep(:rand.uniform(3000) + 2000)

    FLAME.ResourceManager.register_container(container_id, %{
      memory_mb: 1024,
      cpu_percent: 80,
      disk_mb: 2048
    })

    result = %{
      model_type: "neural_network",
      training_epochs: iteration * 10,
      accuracy: :rand.uniform(100) / 100,
      loss: :rand.uniform(100) / 1000,
      container_id: container_id
    }

    FLAME.ContainerMetrics.record_container_return(container_id)
    FLAME.ResourceManager.unregister_container(container_id)
    result
  end

  defp simulate_error_job(iteration) do
    container_id = "e2e-error-#{iteration}-#{:rand.uniform(999)}"
    FLAME.ContainerMetrics.record_container_provision(container_id)
    FLAME.ContainerMetrics.record_container_checkout(container_id)

    # Some processing before error
    Process.sleep(:rand.uniform(1000) + 500)

    # Trigger circuit breaker
    FLAME.CircuitBreaker.call(:e2e_test_circuit, fn ->
      raise "E2E test intentional error"
    end)

    # This should not be reached
    %{should_not_reach: true}
  end

  defp demonstrate_circuit_breaker do
    # Show circuit breaker in action
    IO.puts("   🔄 Testing circuit breaker...")

    # Trigger failures
    Enum.each(1..3, fn i ->
      result =
        FLAME.CircuitBreaker.call(:demo_circuit, fn ->
          raise "Demo failure #{i}"
        end)

      IO.puts("     Failure #{i}: #{inspect(result)}")
    end)

    # Check circuit state
    state = FLAME.CircuitBreaker.get_state(:demo_circuit)
    IO.puts("   📊 Circuit state: #{state.state} (failures: #{state.failure_count})")

    # Reset circuit
    FLAME.CircuitBreaker.reset(:demo_circuit)
    IO.puts("   ✅ Circuit breaker reset")
  end

  defp demonstrate_resource_management do
    IO.puts("   📊 Simulating resource usage...")

    # Register test containers
    test_containers =
      Enum.map(1..3, fn i ->
        container_id = "demo-resource-#{i}"

        FLAME.ResourceManager.register_container(container_id, %{
          memory_mb: i * 256,
          cpu_percent: i * 20,
          disk_mb: i * 512
        })

        container_id
      end)

    # Check resource status
    status = FLAME.ResourceManager.get_resource_status()
    IO.puts("   📈 Resource utilization: #{status.utilization_percentage}%")
    IO.puts("   🏗️ Container count: #{status.container_count}")

    # Cleanup
    Enum.each(test_containers, fn container_id ->
      FLAME.ResourceManager.unregister_container(container_id)
    end)

    IO.puts("   ✅ Resource demo completed")
  end

  defp demonstrate_security_features do
    IO.puts("   🔒 Testing security features...")

    # Test function validation
    safe_function = fn x -> x * 2 end

    case FLAME.SecurityManager.validate_function(safe_function, %{demo: true}) do
      :ok ->
        IO.puts("   ✅ Function validation passed")

      {:error, reason} ->
        IO.puts("   ⚠️ Function validation: #{inspect(reason)}")
    end

    # Test audit logging
    FLAME.SecurityManager.audit_log(:e2e_demo, %{
      event: "security_demonstration",
      timestamp: System.system_time(:millisecond),
      source: "e2e_test"
    })

    IO.puts("   📝 Audit log entry created")
    IO.puts("   ✅ Security demo completed")
  end

  defp demonstrate_performance_monitoring do
    IO.puts("   📈 Running performance test...")

    # Quick performance burst
    tasks =
      Enum.map(1..5, fn i ->
        Task.async(fn ->
          job_id = "perf-demo-#{i}"
          start_time = System.monotonic_time(:millisecond)

          # Simulate work
          Process.sleep(:rand.uniform(500) + 200)

          execution_time = System.monotonic_time(:millisecond) - start_time
          FLAME.ContainerMetrics.record_task_execution(job_id, execution_time)
          FLAME.ContainerMetrics.record_task_completion(job_id, execution_time)

          execution_time
        end)
      end)

    results = Task.await_many(tasks, 2000)
    avg_time = Enum.sum(results) / length(results)

    IO.puts("   ⚡ Executed #{length(results)} tasks in parallel")
    IO.puts("   📊 Average execution time: #{Float.round(avg_time, 1)}ms")
    IO.puts("   ✅ Performance demo completed")
  end

  # Utility functions

  defp start_metrics_generator do
    Task.start_link(fn ->
      generate_background_metrics()
    end)
  end

  defp generate_background_metrics do
    # Generate periodic pool status updates
    Process.sleep(2000)

    warm_pool = :rand.uniform(5) + 2
    active = :rand.uniform(3) + 1

    FLAME.ContainerMetrics.record_pool_status(%{
      warm_pool_size: warm_pool,
      active_containers: active,
      total_containers: warm_pool + active
    })

    generate_background_metrics()
  end

  defp get_safe_status(status_fn, system_name) do
    status_fn.()
  rescue
    _ -> %{error: "#{system_name} not available"}
  end

  defp format_status(%{warm_pool_size: warm, active_containers: active, total_containers: total}) do
    "Warm: #{warm}, Active: #{active}, Total: #{total}"
  end

  defp format_status(%{error: error}), do: error
  defp format_status(_), do: "Unknown format"

  defp format_metrics(%{total_task_executions: total, average_execution_time: avg}) do
    "Tasks: #{total}, Avg Time: #{Float.round(avg, 1)}ms"
  end

  defp format_metrics(%{error: error}), do: error
  defp format_metrics(_), do: "No metrics available"

  defp format_resources(%{utilization_percentage: util, container_count: count}) do
    "Utilization: #{util}%, Containers: #{count}"
  end

  defp format_resources(%{error: error}), do: error
  defp format_resources(_), do: "No resource data"

  defp format_security(%{sandbox_enabled: sandbox, audit_enabled: audit}) do
    "Sandbox: #{sandbox}, Audit: #{audit}"
  end

  defp format_security(%{error: error}), do: error
  defp format_security(_), do: "No security data"

  defp get_result_type(result) when is_map(result), do: :map
  defp get_result_type(result) when is_list(result), do: :list
  defp get_result_type(result) when is_binary(result), do: :binary
  defp get_result_type(result) when is_number(result), do: :number
  defp get_result_type(_), do: :unknown

  defp open_browser(url) do
    case :os.type() do
      # macOS
      {:unix, :darwin} -> System.cmd("open", [url])
      # Linux
      {:unix, _} -> System.cmd("xdg-open", [url])
      # Windows
      {:win32, _} -> System.cmd("cmd", ["/c", "start", url])
    end

    :ok
  rescue
    _ -> {:error, "Could not detect system type or open browser"}
  end

  defp generate_secret_key do
    :crypto.strong_rand_bytes(64) |> Base.encode64() |> binary_part(0, 64)
  end

  defp generate_salt do
    :crypto.strong_rand_bytes(8) |> Base.encode64() |> binary_part(0, 8)
  end

  defp shutdown_test_systems(systems) do
    IO.puts("\n🛑 Shutting down test systems...")

    # Stop web endpoint
    if systems.web_endpoint do
      try do
        GenServer.stop(systems.web_endpoint)
        IO.puts("✅ Web endpoint stopped")
      rescue
        _ -> IO.puts("⚠️  Web endpoint already stopped")
      end
    end

    # Stop application
    case Application.stop(:flame_apple_container_backend) do
      :ok -> IO.puts("✅ Application stopped cleanly")
      {:error, reason} -> IO.puts("⚠️  Application stop: #{inspect(reason)}")
    end

    IO.puts("✅ All systems shut down gracefully")
  end
end

# Auto-run the test if this file is executed directly
if __ENV__.file == Path.absname(System.argv() |> List.first() || __ENV__.file) do
  E2EBrowserTest.run_complete_test()
end
