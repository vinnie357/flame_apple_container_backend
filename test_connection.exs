#!/usr/bin/env elixir

# Manual test script for Erlang node connection
Mix.install([
  {:flame, "~> 0.1.0"},
  {:jason, "~> 1.0"}
])

defmodule ConnectionTest do
  require Logger
  
  def test_container_connection do
    Logger.info("Starting connection test...")
    
    # Start this node with a specific name and cookie
    node_name = :"test_host@#{get_hostname()}.test.local"
    cookie = :test_cookie_123
    
    Logger.info("Starting node as: #{node_name}")
    case Node.start(node_name, :longnames) do
      {:ok, _} -> 
        Logger.info("Node started successfully")
        Node.set_cookie(cookie)
      {:error, reason} ->
        Logger.error("Failed to start node: #{inspect(reason)}")
        return {:error, :node_start_failed}
    end
    
    # Load our backend module
    Code.compile_file("lib/flame/apple_containers_backend.ex")
    
    # Initialize backend
    opts = [
      erlang_cookie: "test_cookie_123",
      dns_domain: "test.local",
      container_prefix: "test-worker"
    ]
    
    {:ok, backend} = FLAME.AppleContainersBackend.init(opts)
    Logger.info("Backend initialized")
    
    # Try to boot a container
    case FLAME.AppleContainersBackend.remote_boot(backend) do
      {:ok, {_updated_backend, container_info}} ->
        Logger.info("Container booted successfully: #{inspect(container_info)}")
        
        # Test node connectivity
        remote_node = container_info.node_name
        Logger.info("Testing ping to: #{remote_node}")
        
        case Node.ping(remote_node) do
          :pong ->
            Logger.info("✅ Successfully connected to remote node!")
            
            # Test remote code execution
            result = :rpc.call(remote_node, :erlang, :node, [])
            Logger.info("Remote node reports itself as: #{result}")
            
            # Cleanup
            cleanup_container(container_info.container_name)
            {:ok, :success}
            
          :pang ->
            Logger.error("❌ Failed to ping remote node")
            cleanup_container(container_info.container_name)
            {:error, :ping_failed}
        end
        
      {:error, reason} ->
        Logger.error("❌ Failed to boot container: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  defp get_hostname do
    case System.cmd("hostname", []) do
      {hostname, 0} -> String.trim(hostname)
      _ -> "localhost"
    end
  end
  
  defp cleanup_container(container_name) do
    Logger.info("Cleaning up container: #{container_name}")
    System.cmd("container", ["stop", container_name])
  end
end

# Run the test
ConnectionTest.test_container_connection()
|> case do
  {:ok, :success} -> 
    IO.puts("🎉 Connection test passed!")
    System.halt(0)
  {:error, reason} -> 
    IO.puts("💥 Connection test failed: #{inspect(reason)}")
    System.halt(1)
end