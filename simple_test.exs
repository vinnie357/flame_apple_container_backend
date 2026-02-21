#!/usr/bin/env elixir

# Simple test to verify container starts and EPMD works
defmodule SimpleTest do
  require Logger
  
  def test_container_boot do
    Logger.info("Testing container boot...")
    
    container_name = "test-flame-worker-#{:rand.uniform(999)}"
    node_name = "#{container_name}@#{container_name}.test.local"
    
    # Start container
    cmd = [
      "container", "run",
      "--name", container_name,
      "--detach", "--rm",
      "--env", "NODE_NAME=#{node_name}",
      "--env", "ERLANG_COOKIE=test_cookie_123",
      "flame-worker:latest"
    ]
    
    Logger.info("Starting container: #{container_name}")
    
    case System.cmd("container", tl(cmd)) do
      {_output, 0} ->
        Logger.info("✅ Container started successfully")
        
        # Wait a bit for startup
        Process.sleep(5000)
        
        # Check if EPMD is running
        result = case System.cmd("container", ["exec", container_name, "epmd", "-names"]) do
          {output, 0} ->
            Logger.info("✅ EPMD output: #{String.trim(output)}")
            
            # Check if our node is registered
            if String.contains?(output, "name ") do
              Logger.info("✅ Node registered with EPMD")
              
              # Check container networking
              case System.cmd("container", ["inspect", container_name]) do
                {inspect_output, 0} ->
                  if String.contains?(inspect_output, "running") do
                    Logger.info("✅ Container is running")
                    :ok
                  else
                    Logger.error("❌ Container not in running state")
                    :error
                  end
                {_, _} ->
                  Logger.error("❌ Failed to inspect container")
                  :error
              end
            else
              Logger.error("❌ No nodes registered with EPMD")
              :error
            end
            
          {error, code} ->
            Logger.error("❌ EPMD check failed (#{code}): #{error}")
            :error
        end
        
        # Cleanup
        Logger.info("Cleaning up container...")
        System.cmd("container", ["stop", container_name])
        result
        
      {error, code} ->
        Logger.error("❌ Failed to start container (#{code}): #{error}")
        :error
    end
  end
end

# Run the test
case SimpleTest.test_container_boot() do
  :ok -> 
    IO.puts("🎉 Container boot test passed!")
    System.halt(0)
  :error -> 
    IO.puts("💥 Container boot test failed!")
    System.halt(1)
end