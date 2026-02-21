#!/usr/bin/env elixir

# Container monitoring script for FLAME workers
Mix.install([
  {:jason, "~> 1.0"}
])

defmodule ContainerMonitor do
  require Logger
  
  def monitor_flame_containers do
    Logger.info("🔍 Monitoring FLAME containers...")
    
    case System.cmd("container", ["list"]) do
      {output, 0} ->
        parse_container_list(output)
        |> filter_flame_containers()
        |> monitor_containers()
        
      {error, code} ->
        Logger.error("❌ Failed to list containers: #{error} (#{code})")
        []
    end
  end
  
  defp parse_container_list(output) do
    lines = String.split(output, "\n")
    [_header | container_lines] = lines
    
    container_lines
    |> Enum.filter(&(String.trim(&1) != ""))
    |> Enum.map(&parse_container_line/1)
    |> Enum.filter(& &1)
  end
  
  defp parse_container_line(line) do
    parts = String.split(line, ~r/\s+/)
    
    case parts do
      [id, image, os, arch, state, addr | _] ->
        %{
          id: id,
          image: image,
          os: os,
          arch: arch,
          state: state,
          addr: addr
        }
      _ -> nil
    end
  end
  
  defp filter_flame_containers(containers) do
    containers
    |> Enum.filter(fn container ->
      String.contains?(container.image, "flame") or
      String.contains?(container.id, "flame")
    end)
  end
  
  defp monitor_containers(containers) do
    Logger.info("📊 Found #{length(containers)} FLAME containers")
    
    containers
    |> Enum.each(&monitor_single_container/1)
    
    containers
  end
  
  defp monitor_single_container(container) do
    Logger.info("🔍 Monitoring container #{container.id}")
    Logger.info("  Image: #{container.image}")
    Logger.info("  State: #{container.state}")
    Logger.info("  Address: #{container.addr}")
    
    # Test HTTP health if it's a flame-http container
    if String.contains?(container.image, "flame-http") and container.state == "running" do
      test_container_health(container)
    end
    
    # Get detailed container info
    get_container_details(container.id)
  end
  
  defp test_container_health(container) do
    health_url = "http://#{container.addr}:4000/health"
    
    case System.cmd("curl", ["-s", "-f", health_url]) do
      {response, 0} ->
        case Jason.decode(response) do
          {:ok, data} ->
            Logger.info("  ✅ Health: #{data["status"]}")
          _ ->
            Logger.info("  ⚠️  Health: Response not JSON")
        end
        
      {_, _} ->
        Logger.info("  ❌ Health: Unreachable")
    end
  end
  
  defp get_container_details(container_id) do
    case System.cmd("container", ["inspect", container_id]) do
      {output, 0} ->
        # Parse basic info from inspect output
        memory_usage = extract_metric(output, "memory")
        cpu_usage = extract_metric(output, "cpu")
        
        Logger.info("  📈 Memory: #{memory_usage || "N/A"}")
        Logger.info("  📈 CPU: #{cpu_usage || "N/A"}")
        
      {error, code} ->
        Logger.warn("  ⚠️  Could not inspect container: #{error} (#{code})")
    end
  end
  
  defp extract_metric(output, metric) do
    # This is a simplified metric extraction
    # In a real implementation, you'd parse the JSON output properly
    case Regex.run(~r/"#{metric}":\s*"([^"]+)"/, output) do
      [_, value] -> value
      _ -> nil
    end
  end
  
  def continuous_monitor(interval_seconds \\ 30) do
    Logger.info("🔄 Starting continuous monitoring (#{interval_seconds}s intervals)")
    
    Stream.repeatedly(fn ->
      monitor_flame_containers()
      Logger.info("💤 Sleeping for #{interval_seconds} seconds...")
      Process.sleep(interval_seconds * 1000)
    end)
    |> Stream.run()
  end
end

# Usage
case System.argv() do
  ["continuous"] ->
    ContainerMonitor.continuous_monitor()
    
  ["continuous", interval] ->
    {interval_int, _} = Integer.parse(interval)
    ContainerMonitor.continuous_monitor(interval_int)
    
  _ ->
    ContainerMonitor.monitor_flame_containers()
end