#!/usr/bin/env elixir

# Test script to run Priority 2 tests
defmodule Priority2TestRunner do
  def run_specific_tests do
    # Priority 2 tests as per the task description
    tests = [
      "test/flame/apple_containers/pool_test.exs:137",    # Container lifecycle handles container acquisition timeout
      "test/flame/apple_containers/pool_test.exs:116",    # Container lifecycle handles multiple concurrent acquisitions
      "test/flame/apple_containers/manager_test.exs:88",  # Task execution executes simple task successfully (fixed line)
      "test/flame/apple_containers/manager_test.exs:100", # Task execution executes multiple tasks concurrently (fixed line)
      "test/flame/apple_containers/pool_test.exs:493",    # Resource management respects resource limits configuration (fixed line)
      "test/flame/apple_containers/pool_test.exs:229",    # Pool scaling rejects scaling beyond limits
      "test/flame/apple_containers/manager_test.exs:358", # Pool scaling rejects scaling beyond max pool size (fixed line)
      "test/flame/apple_containers/pool_test.exs:360"     # Error handling handles container creation failures gracefully
    ]
    
    IO.puts("Running Priority 2 tests...")
    
    results = for test_location <- tests do
      IO.puts("\n=== Running #{test_location} ===")
      
      result = System.cmd("mix", ["test", "--trace", test_location, "--max-failures", "1"], 
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )
      
      case result do
        {_output, 0} -> 
          IO.puts("✅ PASSED")
          :passed
        {output, exit_code} -> 
          IO.puts("❌ FAILED (exit code: #{exit_code})")
          # Print last few lines of output to understand failure
          lines = String.split(output, "\n")
          relevant_lines = lines |> Enum.take(-10) |> Enum.join("\n")
          IO.puts("Last output:\n#{relevant_lines}")
          :failed
      end
    end
    
    passed = Enum.count(results, &(&1 == :passed))
    failed = Enum.count(results, &(&1 == :failed))
    
    IO.puts("\n=== SUMMARY ===")
    IO.puts("Passed: #{passed}")
    IO.puts("Failed: #{failed}")
    IO.puts("Total: #{passed + failed}")
    
    if failed == 0 do
      IO.puts("🎉 ALL PRIORITY 2 TESTS PASSED!")
    else
      IO.puts("⚠️  #{failed} tests still failing")
    end
  end
end

Priority2TestRunner.run_specific_tests()