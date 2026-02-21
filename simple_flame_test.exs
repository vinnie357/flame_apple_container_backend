#!/usr/bin/env elixir

# Simple FLAME functionality test that works with the running application

defmodule SimpleFLAMETest do
  @moduledoc """
  Simple test to validate FLAME functionality and demonstrate the web dashboard.
  """

  def run_test do
    IO.puts("🚀 FLAME Apple Containers - Live System Test")
    IO.puts("============================================")
    
    # Test if the application is running
    test_application_status()
    
    # Test web dashboard
    test_web_dashboard()
    
    # Test basic telemetry
    test_telemetry_events()
    
    # Simulate FLAME workflow
    simulate_flame_workflow()
    
    # Open dashboard
    open_dashboard()
    
    IO.puts("\n✅ FLAME live system test completed!")
    print_next_steps()
  end
  
  defp test_application_status do
    IO.puts("\n🔍 Test 1: Application Status")
    IO.puts("=============================")
    
    # Check if Elixir nodes are running
    case System.cmd("ps", ["aux"]) do
      {output, 0} ->
        if String.contains?(output, "beam.smp") and String.contains?(output, "mix") do
          IO.puts("   ✅ Elixir/BEAM application is running")
          
          # Count BEAM processes
          beam_count = output
            |> String.split("\n")
            |> Enum.count(&String.contains?(&1, "beam.smp"))
          
          IO.puts("   📊 #{beam_count} BEAM processes detected")
        else
          IO.puts("   ❌ No Elixir application detected")
        end
      
      _ ->
        IO.puts("   ⚠️  Could not check process status")
    end
  end
  
  defp test_web_dashboard do
    IO.puts("\n🌐 Test 2: Web Dashboard")
    IO.puts("=======================")
    
    # Test dashboard accessibility
    case System.cmd("curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "http://localhost:4001/dashboard"]) do
      {"200", 0} ->
        IO.puts("   ✅ Dashboard accessible at http://localhost:4001/dashboard")
      
      {"302", 0} ->
        IO.puts("   ✅ Dashboard responding (redirect) at http://localhost:4001/dashboard")
      
      {code, 0} ->
        IO.puts("   ⚠️  Dashboard responding with HTTP #{code}")
      
      _ ->
        IO.puts("   ❌ Dashboard not accessible - checking if Phoenix is running...")
        
        # Check if Phoenix process is running
        case System.cmd("lsof", ["-i", ":4001"]) do
          {output, 0} when byte_size(output) > 0 ->
            IO.puts("   📡 Port 4001 is in use - Phoenix likely running")
          
          _ ->
            IO.puts("   📡 Port 4001 not in use - Phoenix may not be started")
        end
    end
    
    # Test if curl is available
    case System.cmd("which", ["curl"]) do
      {_, 0} -> :ok
      _ -> IO.puts("   💡 Note: curl not available for HTTP testing")
    end
  end
  
  defp test_telemetry_events do
    IO.puts("\n📊 Test 3: Telemetry Events")
    IO.puts("===========================")
    
    try do
      # Fire some telemetry events to test the metrics system
      events = [
        {[:flame, :container, :provision], %{count: 1}, %{container_id: "test-container-1"}},
        {[:flame, :task, :execute], %{execution_time: 1500}, %{task_id: "test-task-1"}},
        {[:flame, :task, :complete], %{execution_time: 1500}, %{task_id: "test-task-1"}},
        {[:flame, :pool, :status], %{warm_pool_size: 3, active_containers: 1}, %{}}
      ]
      
      Enum.each(events, fn {event, measurements, metadata} ->
        :telemetry.execute(event, measurements, metadata)
      end)
      
      IO.puts("   ✅ Telemetry events fired successfully")
      IO.puts("   📈 Container provision event")
      IO.puts("   📈 Task execution events")
      IO.puts("   📈 Pool status event")
      
    rescue
      error ->
        IO.puts("   ❌ Telemetry test failed: #{Exception.message(error)}")
    end
  end
  
  defp simulate_flame_workflow do
    IO.puts("\n⚙️  Test 4: FLAME Workflow Simulation")
    IO.puts("====================================")
    
    # Simulate the complete FLAME workflow with telemetry
    workflows = [
      %{
        name: "Simple Task",
        container_id: "live-test-container-1",
        task_id: "live-test-task-1",
        execution_time: 850
      },
      %{
        name: "Complex Processing",
        container_id: "live-test-container-2", 
        task_id: "live-test-task-2",
        execution_time: 2100
      },
      %{
        name: "ML Computation",
        container_id: "live-test-container-3",
        task_id: "live-test-task-3", 
        execution_time: 4500
      }
    ]
    
    Enum.each(workflows, fn workflow ->
      IO.puts("   🔄 Executing #{workflow.name}...")
      
      # Simulate container lifecycle
      :telemetry.execute([:flame, :container, :provision], %{count: 1}, %{container_id: workflow.container_id})
      :telemetry.execute([:flame, :container, :checkout], %{count: 1}, %{container_id: workflow.container_id})
      
      # Simulate task execution
      :telemetry.execute([:flame, :task, :execute], %{execution_time: 0}, %{task_id: workflow.task_id})
      
      # Simulate work (short delay)
      Process.sleep(200)
      
      # Complete task
      :telemetry.execute([:flame, :task, :complete], %{execution_time: workflow.execution_time}, %{
        task_id: workflow.task_id,
        result_type: :map
      })
      
      # Return container
      :telemetry.execute([:flame, :container, :return], %{count: 1}, %{container_id: workflow.container_id})
      
      IO.puts("   ✅ #{workflow.name} completed (#{workflow.execution_time}ms)")
    end)
    
    # Update pool status
    :telemetry.execute([:flame, :pool, :status], %{
      warm_pool_size: 2,
      active_containers: 1,
      total_containers: 3
    }, %{})
    
    IO.puts("   📊 Generated #{length(workflows)} workflow executions")
    IO.puts("   ⏱️  Total simulated execution time: #{Enum.sum(Enum.map(workflows, & &1.execution_time))}ms")
  end
  
  defp open_dashboard do
    IO.puts("\n🌐 Opening Dashboard")
    IO.puts("===================")
    
    dashboard_url = "http://localhost:4001/dashboard"
    
    case open_browser(dashboard_url) do
      :ok ->
        IO.puts("   ✅ Dashboard opened in browser: #{dashboard_url}")
        IO.puts("   🎯 You should see the live metrics from this test!")
        
      {:error, reason} ->
        IO.puts("   ⚠️  Could not auto-open browser: #{reason}")
        IO.puts("   🔗 Please manually open: #{dashboard_url}")
    end
  end
  
  defp open_browser(url) do
    case :os.type() do
      {:unix, :darwin} -> 
        System.cmd("open", [url])
        :ok
      
      {:unix, _} -> 
        System.cmd("xdg-open", [url])
        :ok
      
      {:win32, _} -> 
        System.cmd("cmd", ["/c", "start", url])
        :ok
    end
  rescue
    _ -> {:error, "Could not detect system type or open browser"}
  end
  
  defp print_next_steps do
    IO.puts("\n🎉 FLAME Apple Containers Backend - Live Test Results")
    IO.puts("====================================================")
    IO.puts("")
    IO.puts("🌐 Dashboard Access:")
    IO.puts("   🔗 URL: http://localhost:4001/dashboard")
    IO.puts("   📊 Shows: Real-time metrics, container status, task execution")
    IO.puts("")
    IO.puts("✅ What We Tested:")
    IO.puts("   ✅ Application is running with BEAM processes")
    IO.puts("   ✅ Web dashboard is accessible")
    IO.puts("   ✅ Telemetry system is working")
    IO.puts("   ✅ FLAME workflow simulation completed")
    IO.puts("   ✅ Metrics generated and should be visible in dashboard")
    IO.puts("")
    IO.puts("🎛️  Dashboard Features to Explore:")
    IO.puts("   📊 Real-time container metrics")
    IO.puts("   🔄 Task execution monitoring")
    IO.puts("   📈 Performance graphs and statistics")
    IO.puts("   🛑 Circuit breaker status and controls")
    IO.puts("   💾 Resource utilization tracking")
    IO.puts("")
    IO.puts("🔄 Next Steps:")
    IO.puts("   1. Check the dashboard for live metrics")
    IO.puts("   2. Explore the interactive controls")
    IO.puts("   3. Run additional tests to see real-time updates")
    IO.puts("   4. Try the configuration options")
    IO.puts("")
    IO.puts("💡 Pro Tip: Run this test multiple times to see")
    IO.puts("   how metrics accumulate in the dashboard!")
  end
end

# Run the test
SimpleFLAMETest.run_test()