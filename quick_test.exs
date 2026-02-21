#!/usr/bin/env elixir

# Quick test of HTTP FLAME worker
Mix.install([
  {:req, "~> 0.4.0"},
  {:jason, "~> 1.0"}
])

defmodule QuickTest do
  require Logger
  
  def test do
    Logger.info("🚀 Quick HTTP FLAME test...")
    
    # Start container
    container_name = "quick-test-#{:rand.uniform(999)}"
    
    Logger.info("Starting container: #{container_name}")
    
    case System.cmd("container", [
      "run", "--name", container_name, "--detach", "--rm",
      "--env", "FLAME_WORKER_PORT=4000",
      "flame-http:latest"
    ]) do
      {_, 0} ->
        Logger.info("✅ Container started")
        
        # Wait and get IP
        Process.sleep(8000)
        
        case System.cmd("container", ["list"]) do
          {output, 0} ->
            # Extract IP from container list
            lines = String.split(output, "\n")
            container_line = Enum.find(lines, &String.contains?(&1, container_name))
            
            if container_line do
              ip = case Regex.run(~r/(\d+\.\d+\.\d+\.\d+)/, container_line) do
                [_, ip] -> ip
                _ -> nil
              end
              
              if ip do
                Logger.info("🌐 Container IP: #{ip}")
                
                # Test endpoints
                test_health(ip) && test_execute(ip)
              else
                Logger.error("❌ Could not extract IP")
                false
              end
            else
              Logger.error("❌ Container not found in list")
              false
            end
            
          _ ->
            Logger.error("❌ Failed to list containers")
            false
        end
        |> case do
          true ->
            Logger.info("🎉 Test passed!")
            cleanup(container_name)
            :ok
          false ->
            Logger.error("💥 Test failed!")
            cleanup(container_name)
            :error
        end
        
      {error, code} ->
        Logger.error("❌ Failed to start container: #{error} (#{code})")
        :error
    end
  end
  
  defp test_health(ip) do
    Logger.info("Testing health...")
    
    case Req.get("http://#{ip}:4000/health") do
      {:ok, %{status: 200}} ->
        Logger.info("✅ Health OK")
        true
      _ ->
        Logger.error("❌ Health failed")
        false
    end
  end
  
  defp test_execute(ip) do
    Logger.info("Testing execution...")
    
    payload = %{"function" => "3 + 4", "args" => []}
    
    case Req.post("http://#{ip}:4000/execute", json: payload) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"result" => 7}} ->
            Logger.info("✅ Execution OK")
            true
          _ ->
            Logger.error("❌ Wrong result")
            false
        end
      _ ->
        Logger.error("❌ Execution failed")
        false
    end
  end
  
  defp cleanup(container_name) do
    System.cmd("container", ["stop", container_name])
  end
end

case QuickTest.test() do
  :ok -> System.halt(0)
  :error -> System.halt(1)
end