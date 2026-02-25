defmodule FLAME.BenchmarkSuite do
  @moduledoc """
  Comprehensive benchmarking suite for Apple Containers FLAME backend.

  Provides:
  - Performance benchmarks comparing with other FLAME backends
  - Container startup time measurements
  - Task execution throughput testing
  - Resource utilization analysis
  - Scaling behavior evaluation
  """

  use GenServer
  require Logger

  defstruct [
    :benchmark_config,
    :results,
    :running_benchmarks,
    :test_scenarios
  ]

  @default_config %{
    container_startup_iterations: 10,
    task_execution_iterations: 100,
    # 1 minute
    throughput_test_duration: 60_000,
    # 5 minutes
    scaling_test_duration: 300_000,
    concurrent_task_counts: [1, 5, 10, 20, 50],
    task_complexity_levels: [:simple, :medium, :complex],
    output_formats: [:console, :json, :csv]
  }

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init(opts) do
    clean_opts = if is_list(opts), do: Keyword.delete(opts, :name), else: opts
    config = Keyword.get(clean_opts, :config, %{}) |> merge_default_config()

    state = %__MODULE__{
      benchmark_config: config,
      results: %{},
      running_benchmarks: %{},
      test_scenarios: initialize_test_scenarios()
    }

    Logger.info("Benchmark suite initialized")
    {:ok, state}
  end

  def run_full_benchmark_suite(output_format \\ :console, server \\ __MODULE__) do
    GenServer.call(server, {:run_full_suite, output_format}, :infinity)
  end

  def run_benchmark(benchmark_name, opts \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:run_benchmark, benchmark_name, opts}, :infinity)
  end

  def get_benchmark_results(benchmark_name \\ nil, server \\ __MODULE__) do
    GenServer.call(server, {:get_results, benchmark_name})
  end

  def compare_with_backend(other_backend, scenarios \\ nil, server \\ __MODULE__) do
    GenServer.call(server, {:compare_backends, other_backend, scenarios}, :infinity)
  end

  # GenServer callbacks

  def handle_call({:run_full_suite, output_format}, _from, state) do
    Logger.info("Starting full benchmark suite")

    benchmarks = [
      :container_startup,
      :task_execution_latency,
      :throughput_test,
      :resource_utilization,
      :scaling_behavior,
      :error_recovery,
      :memory_efficiency
    ]

    results =
      Enum.reduce(benchmarks, %{}, fn benchmark, acc ->
        Logger.info("Running benchmark: #{benchmark}")

        case run_benchmark_impl(benchmark, state, []) do
          {:ok, result} ->
            Map.put(acc, benchmark, result)

          {:error, reason} ->
            Logger.error("Benchmark #{benchmark} failed: #{inspect(reason)}")
            Map.put(acc, benchmark, %{error: reason})
        end
      end)

    # Generate report
    report = generate_benchmark_report(results, output_format)

    state = %{state | results: Map.merge(state.results, results)}

    {:reply, {:ok, report}, state}
  end

  def handle_call({:run_benchmark, benchmark_name, opts}, _from, state) do
    case run_benchmark_impl(benchmark_name, state, opts) do
      {:ok, result} ->
        state = put_in(state.results[benchmark_name], result)
        {:reply, {:ok, result}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_results, benchmark_name}, _from, state) do
    results =
      if benchmark_name do
        Map.get(state.results, benchmark_name)
      else
        state.results
      end

    {:reply, results, state}
  end

  def handle_call({:compare_backends, other_backend, scenarios}, _from, state) do
    comparison = run_backend_comparison(other_backend, scenarios, state)
    {:reply, comparison, state}
  end

  # Private functions

  defp merge_default_config(config) do
    Map.merge(@default_config, config)
  end

  defp initialize_test_scenarios do
    %{
      simple_task: fn ->
        Enum.sum(1..1000)
      end,
      medium_task: fn ->
        # CPU-intensive task
        data = Enum.map(1..10_000, &(&1 * :rand.uniform(100)))
        Enum.sort(data)
      end,
      complex_task: fn ->
        # Memory and CPU intensive task
        matrix = for i <- 1..100, j <- 1..100, do: {i, j, i * j}

        matrix
        |> Enum.group_by(fn {i, _j, _product} -> rem(i, 10) end)
        |> Enum.map(fn {_key, values} ->
          Enum.reduce(values, 0, fn {_i, _j, product}, acc -> acc + product end)
        end)
        |> Enum.sum()
      end,
      io_task: fn ->
        # Simulate I/O operations
        Process.sleep(100)
        "I/O operation completed"
      end,
      error_task: fn ->
        if :rand.uniform(10) > 8 do
          raise "Intentional test error"
        else
          "Success"
        end
      end
    }
  end

  defp run_benchmark_impl(:container_startup, state, _opts) do
    Logger.info("Running container startup benchmark")

    iterations = state.benchmark_config.container_startup_iterations

    startup_times =
      Enum.map(1..iterations, fn i ->
        Logger.debug("Container startup iteration #{i}/#{iterations}")

        start_time = System.monotonic_time(:millisecond)

        {:ok, backend} =
          FLAME.AppleContainersBackend.init(
            image: "flame-worker:test",
            dns_domain: "test.local",
            container_prefix: "benchmark-test",
            erlang_cookie: "benchmark_cookie"
          )

        case FLAME.AppleContainersBackend.remote_boot(backend) do
          {:ok, _pid, _ref} ->
            end_time = System.monotonic_time(:millisecond)
            startup_time = end_time - start_time

            # In test mode, cleanup is handled automatically
            startup_time

          {:error, reason} ->
            Logger.warning("Container startup failed in iteration #{i}: #{inspect(reason)}")
            nil
        end
      end)

    valid_times = Enum.reject(startup_times, &is_nil/1)

    valid_count = Enum.count(valid_times)

    if valid_count > 0 do
      {:ok,
       %{
         total_iterations: iterations,
         successful_startups: valid_count,
         failed_startups: iterations - valid_count,
         min_startup_time: Enum.min(valid_times),
         max_startup_time: Enum.max(valid_times),
         avg_startup_time: calculate_average(valid_times),
         median_startup_time: calculate_median(valid_times),
         p95_startup_time: calculate_percentile(valid_times, 95),
         startup_times: valid_times
       }}
    else
      {:error, :all_startups_failed}
    end
  end

  defp run_benchmark_impl(:task_execution_latency, state, _opts) do
    Logger.info("Running task execution latency benchmark")

    iterations = state.benchmark_config.task_execution_iterations
    results = %{}

    # Test each complexity level
    results =
      Enum.reduce(state.benchmark_config.task_complexity_levels, results, fn complexity, acc ->
        task_function = state.test_scenarios[:"#{complexity}_task"]
        benchmark_complexity_level(acc, complexity, task_function, iterations)
      end)

    {:ok, results}
  end

  defp run_benchmark_impl(:throughput_test, state, _opts) do
    Logger.info("Running throughput benchmark")

    duration = state.benchmark_config.throughput_test_duration
    task_function = state.test_scenarios.simple_task

    results =
      Enum.reduce(state.benchmark_config.concurrent_task_counts, %{}, fn concurrency, acc ->
        benchmark_throughput_at_concurrency(acc, concurrency, task_function, duration)
      end)

    {:ok, results}
  end

  defp run_benchmark_impl(:resource_utilization, state, _opts) do
    Logger.info("Running resource utilization benchmark")

    # Monitor resource usage during various workloads
    baseline = get_current_resource_usage()

    # Test different workload scenarios
    scenarios = [
      {:idle, fn -> Process.sleep(5000) end},
      {:cpu_intensive, state.test_scenarios.complex_task},
      {:memory_intensive,
       fn ->
         # Create large data structures
         data = for _i <- 1..100_000, do: :rand.uniform(1_000_000)
         Enum.sort(data)
       end}
    ]

    results =
      Enum.reduce(scenarios, %{}, fn {scenario_name, task}, acc ->
        Logger.info("Testing resource utilization for #{scenario_name}")

        start_usage = get_current_resource_usage()
        start_time = System.monotonic_time(:millisecond)

        # Execute workload
        task.()

        end_time = System.monotonic_time(:millisecond)
        end_usage = get_current_resource_usage()

        Map.put(acc, scenario_name, %{
          duration_ms: end_time - start_time,
          memory_delta_mb: (end_usage.memory - start_usage.memory) / 1024 / 1024,
          cpu_time_delta: end_usage.cpu_time - start_usage.cpu_time,
          process_count_delta: end_usage.process_count - start_usage.process_count
        })
      end)

    {:ok, Map.put(results, :baseline, baseline)}
  end

  defp run_benchmark_impl(:scaling_behavior, state, _opts) do
    Logger.info("Running scaling behavior benchmark")

    # Test auto-scaling behavior under varying loads
    _duration = state.benchmark_config.scaling_test_duration

    # Record scaling events
    scaling_events = []

    # Simulate load increase
    load_phases = [
      # 10 seconds, 1 task/sec
      {10_000, 1},
      # 20 seconds, 5 tasks/sec
      {20_000, 5},
      # 30 seconds, 10 tasks/sec
      {30_000, 10},
      # 20 seconds, 5 tasks/sec
      {20_000, 5},
      # 10 seconds, 1 task/sec
      {10_000, 1}
    ]

    start_time = System.monotonic_time(:millisecond)

    scaling_events =
      Enum.reduce(load_phases, scaling_events, fn {phase_duration, tasks_per_sec}, events ->
        Logger.info("Load phase: #{tasks_per_sec} tasks/sec for #{phase_duration}ms")

        _phase_start = System.monotonic_time(:millisecond)
        task_interval = 1000 / tasks_per_sec

        # Generate load for this phase
        spawn(fn ->
          generate_load(phase_duration, task_interval, state.test_scenarios.simple_task)
        end)

        # Monitor scaling events during this phase
        Process.sleep(phase_duration)

        pool_status = FLAME.ContainerPool.get_pool_status()

        events ++
          [
            %{
              timestamp: System.monotonic_time(:millisecond) - start_time,
              phase: "#{tasks_per_sec}_tps",
              warm_pool_size: pool_status.warm_pool_size,
              active_containers: pool_status.active_containers,
              total_containers: pool_status.total_containers
            }
          ]
      end)

    {:ok,
     %{
       duration_ms: System.monotonic_time(:millisecond) - start_time,
       scaling_events: scaling_events,
       load_phases: load_phases
     }}
  end

  defp run_benchmark_impl(benchmark_name, _state, _opts) do
    {:error, {:unknown_benchmark, benchmark_name}}
  end

  defp benchmark_complexity_level(acc, complexity, task_function, iterations) do
    execution_times =
      Enum.map(1..iterations, fn _i ->
        start_time = System.monotonic_time(:microsecond)

        case FLAME.call(FLAME.Pool, task_function) do
          {:ok, _result} ->
            end_time = System.monotonic_time(:microsecond)
            end_time - start_time

          {:error, _reason} ->
            nil
        end
      end)

    valid_times = Enum.reject(execution_times, &is_nil/1)

    if valid_times != [] do
      Map.put(acc, complexity, %{
        total_iterations: iterations,
        successful_executions: length(valid_times),
        min_time: Enum.min(valid_times),
        max_time: Enum.max(valid_times),
        avg_time: calculate_average(valid_times),
        median_time: calculate_median(valid_times),
        p95_time: calculate_percentile(valid_times, 95),
        p99_time: calculate_percentile(valid_times, 99)
      })
    else
      Map.put(acc, complexity, %{error: :all_executions_failed})
    end
  end

  defp benchmark_throughput_at_concurrency(acc, concurrency, task_function, duration) do
    Logger.info("Testing throughput with #{concurrency} concurrent tasks")

    start_time = System.monotonic_time(:millisecond)
    end_time = start_time + duration

    # Start concurrent workers
    workers =
      Enum.map(1..concurrency, fn _i ->
        spawn_link(fn -> throughput_worker(task_function, end_time, 0) end)
      end)

    # Wait for test duration
    Process.sleep(duration + 1000)

    # Collect results from workers
    worker_results = Enum.map(workers, &collect_worker_result/1)

    total_tasks = Enum.sum(worker_results)
    tasks_per_second = total_tasks / (duration / 1000)

    Map.put(acc, concurrency, %{
      total_tasks: total_tasks,
      tasks_per_second: Float.round(tasks_per_second, 2),
      duration_ms: duration,
      concurrent_workers: concurrency
    })
  end

  defp collect_worker_result(worker) do
    if Process.alive?(worker) do
      send(worker, {:get_count, self()})

      receive do
        {:count, count} -> count
      after
        1000 -> 0
      end
    else
      0
    end
  end

  defp throughput_worker(task_function, end_time, count) do
    if System.monotonic_time(:millisecond) < end_time do
      case FLAME.call(FLAME.Pool, task_function) do
        {:ok, _result} ->
          throughput_worker(task_function, end_time, count + 1)

        {:error, _reason} ->
          throughput_worker(task_function, end_time, count)
      end
    else
      receive do
        {:get_count, from} -> send(from, {:count, count})
      after
        0 -> :ok
      end
    end
  end

  defp generate_load(duration, interval, task_function) do
    end_time = System.monotonic_time(:millisecond) + duration

    generate_load_loop(end_time, interval, task_function)
  end

  defp generate_load_loop(end_time, interval, task_function) do
    if System.monotonic_time(:millisecond) < end_time do
      spawn(fn -> FLAME.call(FLAME.Pool, task_function) end)
      Process.sleep(trunc(interval))
      generate_load_loop(end_time, interval, task_function)
    end
  end

  defp get_current_resource_usage do
    %{
      memory: :erlang.memory(:total),
      cpu_time: :erlang.statistics(:runtime),
      process_count: :erlang.system_info(:process_count),
      timestamp: System.monotonic_time(:millisecond)
    }
  end

  defp calculate_average([]), do: 0

  defp calculate_average(values) do
    Enum.sum(values) / length(values)
  end

  defp calculate_median([]), do: 0

  defp calculate_median(values) do
    sorted = Enum.sort(values)
    len = length(sorted)

    if rem(len, 2) == 0 do
      (Enum.at(sorted, div(len, 2) - 1) + Enum.at(sorted, div(len, 2))) / 2
    else
      Enum.at(sorted, div(len, 2))
    end
  end

  defp calculate_percentile([], _percentile), do: 0

  defp calculate_percentile(values, percentile) do
    sorted = Enum.sort(values)
    len = length(sorted)
    index = trunc(percentile / 100 * len)
    index = min(index, len - 1)

    Enum.at(sorted, index)
  end

  defp generate_benchmark_report(results, output_format) do
    case output_format do
      :console -> generate_console_report(results)
      :json -> generate_json_report(results)
      :csv -> generate_csv_report(results)
      _ -> generate_console_report(results)
    end
  end

  defp generate_console_report(results) do
    [
      "\n=== FLAME Apple Containers Benchmark Report ===\n",
      "Generated at: #{DateTime.utc_now()}\n\n",
      format_benchmark_section("Container Startup Performance", results[:container_startup]),
      format_benchmark_section("Task Execution Latency", results[:task_execution_latency]),
      format_benchmark_section("Throughput Analysis", results[:throughput_test]),
      format_benchmark_section("Resource Utilization", results[:resource_utilization]),
      format_benchmark_section("Scaling Behavior", results[:scaling_behavior]),
      "\n=== Summary ===\n",
      generate_summary(results),
      "\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp format_benchmark_section(title, nil) do
    "#{title}: No data available\n\n"
  end

  defp format_benchmark_section(title, %{error: error}) do
    "#{title}: Error - #{inspect(error)}\n\n"
  end

  defp format_benchmark_section("Container Startup Performance", data) do
    [
      "Container Startup Performance:\n",
      "  Total Iterations: #{data.total_iterations}\n",
      "  Successful Startups: #{data.successful_startups}\n",
      "  Failed Startups: #{data.failed_startups}\n",
      "  Average Startup Time: #{Float.round(data.avg_startup_time, 2)}ms\n",
      "  Median Startup Time: #{Float.round(data.median_startup_time, 2)}ms\n",
      "  95th Percentile: #{Float.round(data.p95_startup_time, 2)}ms\n",
      "  Min/Max: #{data.min_startup_time}ms / #{data.max_startup_time}ms\n\n"
    ]
  end

  defp format_benchmark_section("Throughput Analysis", data) do
    [
      "Throughput Analysis:\n",
      Enum.map(data, fn {concurrency, results} ->
        "  #{concurrency} concurrent workers: #{results.tasks_per_second} tasks/sec (#{results.total_tasks} total)\n"
      end),
      "\n"
    ]
  end

  defp format_benchmark_section(title, data) do
    "#{title}: #{inspect(data, pretty: true)}\n\n"
  end

  defp generate_json_report(results) do
    Jason.encode!(
      %{
        benchmark_report: %{
          generated_at: DateTime.utc_now(),
          backend_type: "apple_containers",
          results: results
        }
      },
      pretty: true
    )
  end

  defp generate_csv_report(results) do
    # Generate CSV format for key metrics
    headers = ["benchmark", "metric", "value", "unit"]

    rows =
      Enum.flat_map(results, fn {benchmark, data} ->
        extract_csv_metrics(benchmark, data)
      end)

    csv_content = [
      Enum.join(headers, ","),
      Enum.map(rows, fn row -> Enum.join(row, ",") end)
    ]

    Enum.join(List.flatten(csv_content), "\n")
  end

  defp extract_csv_metrics(:container_startup, data) when is_map(data) do
    [
      ["container_startup", "avg_startup_time", data.avg_startup_time, "ms"],
      ["container_startup", "median_startup_time", data.median_startup_time, "ms"],
      ["container_startup", "p95_startup_time", data.p95_startup_time, "ms"],
      [
        "container_startup",
        "success_rate",
        data.successful_startups / data.total_iterations * 100,
        "percent"
      ]
    ]
  end

  defp extract_csv_metrics(:throughput_test, data) when is_map(data) do
    Enum.map(data, fn {concurrency, results} ->
      [
        "throughput_test",
        "tasks_per_second_#{concurrency}_workers",
        results.tasks_per_second,
        "tasks/sec"
      ]
    end)
  end

  defp extract_csv_metrics(_benchmark, _data), do: []

  defp generate_summary(results) do
    startup_perf =
      case results[:container_startup] do
        %{avg_startup_time: time} -> "#{Float.round(time, 1)}ms avg startup"
        _ -> "startup data unavailable"
      end

    max_throughput =
      case results[:throughput_test] do
        data when is_map(data) ->
          max_tps = data |> Enum.map(fn {_k, v} -> v.tasks_per_second end) |> Enum.max()
          "#{max_tps} max tasks/sec"

        _ ->
          "throughput data unavailable"
      end

    "Container startup: #{startup_perf}\nMax throughput: #{max_throughput}\n"
  end

  defp run_backend_comparison(other_backend, _scenarios, _state) do
    # This would run the same benchmarks on different backends for comparison
    # Implementation would depend on the other backend's interface
    Logger.info("Backend comparison not yet implemented")
    %{comparison: "not_implemented", other_backend: other_backend}
  end
end
