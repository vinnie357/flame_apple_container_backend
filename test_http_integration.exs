#!/usr/bin/env elixir

# HTTP-based integration test for FLAME Apple Containers backend
Mix.install([
  {:req, "~> 0.4.0"},
  {:jason, "~> 1.0"}
])

defmodule HTTPIntegrationTest do
  require Logger
  
  def test_full_integration do
    Logger.info("🚀 Starting HTTP-based FLAME integration test...")
    
    container_name = "flame-integration-#{:rand.uniform(999999)}"
    container_port = 4000
    
    # Step 1: Start container
    Logger.info("📦 Starting container: #{container_name}")
    
    cmd = [
      "container", "run",
      "--name", container_name,
      "--detach", "--rm",
      "--env", "FLAME_WORKER_PORT=#{container_port}",
      "flame-http:latest"
    ]
    
    case System.cmd("container", tl(cmd)) do
      {_output, 0} ->
        Logger.info("✅ Container started successfully")
        
        # Step 2: Wait for container to be ready
        container_ip = wait_for_container_ready(container_name)
        
        if container_ip do
          Logger.info("🌐 Container IP: #{container_ip}")
          
          # Step 3: Test HTTP endpoints
          base_url = "http://#{container_ip}:#{container_port}"
          
          test_results = [
            test_health_endpoint(base_url),
            test_info_endpoint(base_url),
            test_simple_execution(base_url),
            test_complex_execution(base_url),
            test_concurrent_execution(base_url)
          ]
          
          # Step 4: Cleanup
          Logger.info("🧹 Cleaning up container...")
          System.cmd("container", ["stop", container_name])
          
          # Step 5: Report results
          passed = Enum.count(test_results, & &1 == :ok)
          total = length(test_results)
          
          if passed == total do
            Logger.info("🎉 All tests passed! (#{passed}/#{total})")
            :ok
          else
            Logger.error("💥 Some tests failed (#{passed}/#{total})")
            :error
          end
        else
          Logger.error("❌ Failed to get container IP")
          System.cmd("container", ["stop", container_name])
          :error
        end
        
      {error, code} ->
        Logger.error("❌ Failed to start container (#{code}): #{error}")
        :error
    end
  end
  
  defp wait_for_container_ready(container_name, retries \\ 10) do
    if retries <= 0 do
      Logger.error("❌ Container readiness timeout")
      nil
    else
      case System.cmd("container", ["inspect", container_name]) do
        {output, 0} ->
          if String.contains?(output, "running") do
            # Get container IP
            case System.cmd("container", ["inspect", container_name]) do
              {inspect_output, 0} ->
                # Parse IP from output (simplified)
                case Regex.run(~r/"Addr":\s*"([^"]+)"/, inspect_output) do
                  [_, ip] -> ip
                  _ -> 
                    Process.sleep(2000)
                    wait_for_container_ready(container_name, retries - 1)
                end
              _ ->
                Process.sleep(2000)
                wait_for_container_ready(container_name, retries - 1)
            end
          else
            Process.sleep(2000)
            wait_for_container_ready(container_name, retries - 1)
          end
        _ ->
          Process.sleep(2000)
          wait_for_container_ready(container_name, retries - 1)
      end
    end
  end
  
  defp test_health_endpoint(base_url) do
    Logger.info("🔍 Testing health endpoint...")
    
    case Req.get("#{base_url}/health") do
      {:ok, %{status: 200, body: body}} ->
        data = Jason.decode!(body)
        
        if data["status"] == "healthy" do
          Logger.info("✅ Health check passed")
          :ok
        else
          Logger.error("❌ Health check failed: #{inspect(data)}")
          :error
        end
        
      {:error, reason} ->
        Logger.error("❌ Health endpoint failed: #{inspect(reason)}")
        :error
    end
  end
  
  defp test_info_endpoint(base_url) do
    Logger.info("🔍 Testing info endpoint...")
    
    case Req.get("#{base_url}/info") do
      {:ok, %{status: 200, body: body}} ->
        data = Jason.decode!(body)
        
        if is_binary(data["container_id"]) and is_integer(data["process_count"]) do
          Logger.info("✅ Info endpoint passed")
          :ok
        else
          Logger.error("❌ Info endpoint invalid data: #{inspect(data)}")
          :error
        end
        
      {:error, reason} ->
        Logger.error("❌ Info endpoint failed: #{inspect(reason)}")
        :error
    end
  end
  
  defp test_simple_execution(base_url) do
    Logger.info("🔍 Testing simple execution...")
    
    payload = %{
      "function" => "1 + 1",
      "args" => []
    }
    
    case Req.post("#{base_url}/execute", json: payload) do
      {:ok, %{status: 200, body: body}} ->
        data = Jason.decode!(body)
        
        if data["status"] == "success" and data["result"] == 2 do
          Logger.info("✅ Simple execution passed")
          :ok
        else
          Logger.error("❌ Simple execution failed: #{inspect(data)}")
          :error
        end
        
      {:error, reason} ->
        Logger.error("❌ Simple execution failed: #{inspect(reason)}")
        :error
    end
  end
  
  defp test_complex_execution(base_url) do
    Logger.info("🔍 Testing complex execution...")
    
    payload = %{
      "function" => "Enum.sum([1, 2, 3, 4, 5])",
      "args" => []
    }
    
    case Req.post("#{base_url}/execute", json: payload) do
      {:ok, %{status: 200, body: body}} ->
        data = Jason.decode!(body)
        
        if data["status"] == "success" and data["result"] == 15 do
          Logger.info("✅ Complex execution passed")
          :ok
        else
          Logger.error("❌ Complex execution failed: #{inspect(data)}")
          :error
        end
        
      {:error, reason} ->
        Logger.error("❌ Complex execution failed: #{inspect(reason)}")
        :error
    end
  end
  
  defp test_concurrent_execution(base_url) do
    Logger.info("🔍 Testing concurrent execution...")
    
    tasks = for i <- 1..3 do
      Task.async(fn ->
        payload = %{
          "function" => "#{i} * 10",
          "args" => []
        }
        
        case Req.post("#{base_url}/execute", json: payload) do
          {:ok, %{status: 200, body: body}} ->
            data = Jason.decode!(body)
            if data["status"] == "success" and data["result"] == i * 10 do
              :ok
            else
              :error
            end
          _ -> :error
        end
      end)
    end
    
    results = Task.await_many(tasks, 10_000)
    passed = Enum.count(results, & &1 == :ok)
    
    if passed == 3 do
      Logger.info("✅ Concurrent execution passed")
      :ok
    else
      Logger.error("❌ Concurrent execution failed (#{passed}/3)")
      :error
    end
  end
end

# Run the test
case HTTPIntegrationTest.test_full_integration() do
  :ok -> 
    IO.puts("🎉 HTTP Integration test passed!")
    System.halt(0)
  :error -> 
    IO.puts("💥 HTTP Integration test failed!")
    System.halt(1)
end