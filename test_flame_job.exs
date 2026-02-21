#!/usr/bin/env elixir

# Test script for FLAME job execution with Apple Containers

require Logger

IO.puts("Starting FLAME test with Apple Containers backend...")

# Wait for application to start
:timer.sleep(2000)

IO.puts("Testing basic FLAME job...")

try do
  result = FLAME.call(FlameAppleContainerBackend.Pool, fn ->
    IO.puts("Hello from Apple Container!")
    2 + 2
  end)
  
  IO.puts("✅ FLAME job completed successfully!")
  IO.puts("Result: #{result}")
  
  # Test a more complex job
  IO.puts("\nTesting more complex job...")
  
  complex_result = FLAME.call(FlameAppleContainerBackend.Pool, fn ->
    list = Enum.to_list(1..10)
    sum = Enum.sum(list)
    %{list: list, sum: sum, timestamp: System.system_time(:millisecond)}
  end)
  
  IO.puts("✅ Complex FLAME job completed!")
  IO.puts("Result: #{inspect(complex_result)}")
  
rescue
  e ->
    IO.puts("❌ FLAME job failed with error:")
    IO.puts("Error: #{inspect(e)}")
    IO.puts("Stacktrace:")
    IO.puts(Exception.format_stacktrace(__STACKTRACE__))
end

IO.puts("\nFLAME test completed.")