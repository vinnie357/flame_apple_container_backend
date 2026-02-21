#!/usr/bin/env elixir

# Debug test to see what's happening with container creation
defmodule DebugPool do
  require Logger
  
  def test_container_creation do
    IO.puts("Starting debug test...")
    
    # Set up backend
    backend_opts = [
      image: "test-worker:latest",
      dns_domain: "test.local",
      container_prefix: "flame-worker",
      mode: :test
    ]
    
    {:ok, backend} = FLAME.AppleContainersBackend.init(backend_opts)
    
    # Start pool
    pool_opts = [
      backend: backend,
      size: 2,
      max_size: 5
    ]
    
    {:ok, pool} = FLAME.AppleContainers.Pool.start_link(pool_opts)
    
    # Wait a bit for initialization
    :timer.sleep(500)
    
    # Get status
    status = FLAME.AppleContainers.Pool.get_status(pool)
    IO.puts("Pool status: #{inspect(status)}")
    
    # Try to acquire a container
    result = FLAME.AppleContainers.Pool.acquire_container(pool, 5000)
    IO.puts("Acquire result: #{inspect(result)}")
    
    # Clean up
    FLAME.AppleContainers.Pool.shutdown(pool)
    
    IO.puts("Test completed")
  end
end

DebugPool.test_container_creation()