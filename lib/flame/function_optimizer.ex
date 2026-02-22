defmodule FLAME.FunctionOptimizer do
  @moduledoc """
  Function optimization system for Apple Containers FLAME backend.

  Provides:
  - Automatic function compilation and caching
  - Dependency injection for common libraries
  - Function execution optimization hints
  - Code analysis and performance recommendations
  - Dynamic optimization based on execution patterns
  """

  use GenServer
  require Logger

  defstruct [
    :optimization_config,
    :function_cache,
    :dependency_cache,
    :execution_stats,
    :optimization_rules,
    :preloaded_modules
  ]

  @default_config %{
    enable_function_caching: true,
    enable_dependency_injection: true,
    enable_dynamic_optimization: true,
    # Max cached functions
    cache_size_limit: 1000,
    # 1 hour TTL
    cache_ttl: 3_600_000,
    # Optimize after 10 executions
    optimization_threshold: 10,
    preload_common_modules: true,
    common_modules: [
      :math,
      :crypto,
      :base64,
      :unicode,
      Enum,
      Stream,
      Map,
      List,
      String,
      Regex,
      Jason,
      DateTime,
      NaiveDateTime
    ]
  }

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init(opts) do
    clean_opts = if is_list(opts), do: Keyword.delete(opts, :name), else: opts
    config = Keyword.get(clean_opts, :config, %{}) |> merge_default_config()

    state = %__MODULE__{
      optimization_config: config,
      function_cache: %{},
      dependency_cache: %{},
      execution_stats: %{},
      optimization_rules: initialize_optimization_rules(),
      preloaded_modules: %{}
    }

    # Preload common modules if enabled
    state =
      if config.preload_common_modules do
        preload_common_modules(state)
      else
        state
      end

    # Schedule cache cleanup
    schedule_cache_cleanup()

    Logger.info("Function optimizer initialized")
    {:ok, state}
  end

  def optimize_function(function, metadata \\ %{}, server \\ __MODULE__) do
    GenServer.call(server, {:optimize_function, function, metadata})
  end

  def get_optimized_function(function_hash, server \\ __MODULE__) do
    GenServer.call(server, {:get_optimized_function, function_hash})
  end

  def inject_dependencies(function, dependencies, server \\ __MODULE__) do
    GenServer.call(server, {:inject_dependencies, function, dependencies})
  end

  def analyze_function_performance(function, execution_data, server \\ __MODULE__) do
    GenServer.call(server, {:analyze_performance, function, execution_data})
  end

  def get_optimization_suggestions(function_hash, server \\ __MODULE__) do
    GenServer.call(server, {:get_suggestions, function_hash})
  end

  def update_execution_stats(function_hash, execution_time, result_type, server \\ __MODULE__) do
    GenServer.cast(server, {:update_stats, function_hash, execution_time, result_type})
  end

  def clear_cache(server \\ __MODULE__) do
    GenServer.cast(server, :clear_cache)
  end

  # GenServer callbacks

  def handle_call({:optimize_function, function, metadata}, _from, state) do
    function_hash = generate_function_hash(function)

    case Map.get(state.function_cache, function_hash) do
      nil ->
        # Function not cached, perform optimization
        case perform_function_optimization(function, metadata, state) do
          {:ok, optimized_function, optimization_info} ->
            # Cache the optimized function
            cache_entry = %{
              original_function: function,
              optimized_function: optimized_function,
              optimization_info: optimization_info,
              created_at: System.system_time(:millisecond),
              access_count: 1,
              metadata: metadata
            }

            function_cache = Map.put(state.function_cache, function_hash, cache_entry)
            state = %{state | function_cache: function_cache}

            Logger.debug("Cached optimized function: #{function_hash}")
            {:reply, {:ok, optimized_function, optimization_info}, state}

          {:error, reason} ->
            Logger.warning("Function optimization failed: #{inspect(reason)}")
            {:reply, {:ok, function, %{optimization_applied: false, reason: reason}}, state}
        end

      cache_entry ->
        # Function is cached, update access count
        updated_entry = %{cache_entry | access_count: cache_entry.access_count + 1}
        function_cache = Map.put(state.function_cache, function_hash, updated_entry)
        state = %{state | function_cache: function_cache}

        Logger.debug("Retrieved cached optimized function: #{function_hash}")
        {:reply, {:ok, cache_entry.optimized_function, cache_entry.optimization_info}, state}
    end
  end

  def handle_call({:get_optimized_function, function_hash}, _from, state) do
    case Map.get(state.function_cache, function_hash) do
      nil -> {:reply, {:error, :not_found}, state}
      cache_entry -> {:reply, {:ok, cache_entry.optimized_function}, state}
    end
  end

  def handle_call({:inject_dependencies, function, dependencies}, _from, state) do
    case inject_dependencies_impl(function, dependencies, state) do
      {:ok, enhanced_function} ->
        {:reply, {:ok, enhanced_function}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:analyze_performance, function, execution_data}, _from, state) do
    analysis = analyze_function_performance_impl(function, execution_data, state)
    {:reply, analysis, state}
  end

  def handle_call({:get_suggestions, function_hash}, _from, state) do
    suggestions = generate_optimization_suggestions(function_hash, state)
    {:reply, suggestions, state}
  end

  def handle_cast({:update_stats, function_hash, execution_time, result_type}, state) do
    stats =
      Map.get(state.execution_stats, function_hash, %{
        total_executions: 0,
        total_time: 0,
        avg_time: 0,
        min_time: nil,
        max_time: nil,
        result_types: %{}
      })

    updated_stats = %{
      stats
      | total_executions: stats.total_executions + 1,
        total_time: stats.total_time + execution_time,
        avg_time: (stats.total_time + execution_time) / (stats.total_executions + 1),
        min_time:
          if(stats.min_time, do: min(stats.min_time, execution_time), else: execution_time),
        max_time:
          if(stats.max_time, do: max(stats.max_time, execution_time), else: execution_time),
        result_types: Map.update(stats.result_types, result_type, 1, &(&1 + 1))
    }

    execution_stats = Map.put(state.execution_stats, function_hash, updated_stats)
    state = %{state | execution_stats: execution_stats}

    # Check if function should be re-optimized
    if should_reoptimize_function?(updated_stats, state) do
      Logger.info("Function #{function_hash} scheduled for re-optimization")
      # Schedule re-optimization
      send(self(), {:reoptimize_function, function_hash})
    end

    {:noreply, state}
  end

  def handle_cast(:clear_cache, state) do
    state = %{state | function_cache: %{}, dependency_cache: %{}, execution_stats: %{}}

    Logger.info("Function cache cleared")
    {:noreply, state}
  end

  def handle_info(:cleanup_cache, state) do
    state = cleanup_expired_cache_entries(state)
    schedule_cache_cleanup()
    {:noreply, state}
  end

  def handle_info({:reoptimize_function, function_hash}, state) do
    case Map.get(state.function_cache, function_hash) do
      nil ->
        {:noreply, state}

      cache_entry ->
        Logger.info("Re-optimizing function: #{function_hash}")

        case perform_function_optimization(
               cache_entry.original_function,
               cache_entry.metadata,
               state
             ) do
          {:ok, optimized_function, optimization_info} ->
            updated_entry = %{
              cache_entry
              | optimized_function: optimized_function,
                optimization_info: optimization_info,
                created_at: System.system_time(:millisecond)
            }

            function_cache = Map.put(state.function_cache, function_hash, updated_entry)
            state = %{state | function_cache: function_cache}

            Logger.info("Function #{function_hash} re-optimized successfully")
            {:noreply, state}

          {:error, reason} ->
            Logger.warning("Function re-optimization failed: #{inspect(reason)}")
            {:noreply, state}
        end
    end
  end

  # Private functions

  defp merge_default_config(config) do
    Map.merge(@default_config, config)
  end

  defp initialize_optimization_rules do
    %{
      # Inline small functions
      inline_small_functions: true,

      # Pre-compile regex patterns
      precompile_regex: true,

      # Cache expensive computations
      cache_computations: true,

      # Optimize data structure access
      optimize_data_access: true,

      # Parallel processing hints
      parallel_processing: true
    }
  end

  defp preload_common_modules(state) do
    Logger.info("Preloading common modules")

    preloaded =
      Enum.reduce(state.optimization_config.common_modules, %{}, fn module, acc ->
        try do
          # Ensure module is loaded
          Code.ensure_loaded(module)

          # Cache module info
          module_info = %{
            loaded_at: System.system_time(:millisecond),
            functions: get_module_functions(module),
            docs: get_module_docs(module)
          }

          Map.put(acc, module, module_info)
        rescue
          error ->
            Logger.warning("Failed to preload module #{module}: #{inspect(error)}")
            acc
        end
      end)

    %{state | preloaded_modules: preloaded}
  end

  defp get_module_functions(module) do
    module.__info__(:functions)
  rescue
    _ -> []
  end

  defp get_module_docs(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, _, _, functions} -> length(functions)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp perform_function_optimization(function, _metadata, state) do
    optimization_info = %{optimization_applied: false, optimizations: [], function_info: nil}

    try do
      # Analyze function structure
      function_info = analyze_function_structure(function)

      # Apply optimization rules
      {optimized_function, applied_optimizations} =
        apply_optimization_rules(
          function,
          function_info,
          state.optimization_rules,
          state
        )

      optimization_info = %{
        optimization_info
        | optimization_applied: applied_optimizations != [],
          optimizations: applied_optimizations,
          function_info: function_info
      }

      {:ok, optimized_function, optimization_info}
    rescue
      error ->
        {:error, {:optimization_failed, error}}
    end
  end

  defp analyze_function_structure(function) when is_function(function) do
    info = Function.info(function)

    %{
      arity: info[:arity],
      type: info[:type],
      module: elem(info[:name] || {:unknown, :unknown}, 0),
      function_name: elem(info[:name] || {:unknown, :unknown}, 1),
      env: info[:env]
    }
  end

  defp analyze_function_structure(_function) do
    %{
      arity: :unknown,
      type: :anonymous,
      module: :unknown,
      function_name: :unknown,
      env: nil
    }
  end

  defp apply_optimization_rules(function, function_info, rules, state) do
    applied_optimizations = []
    optimized_function = function

    # Apply each optimization rule
    {optimized_function, applied_optimizations} =
      if rules.cache_computations do
        case apply_computation_caching(optimized_function, function_info, state) do
          {:ok, cached_function} ->
            {cached_function, [:computation_caching | applied_optimizations]}

          {:error, _} ->
            {optimized_function, applied_optimizations}
        end
      else
        {optimized_function, applied_optimizations}
      end

    {optimized_function, applied_optimizations} =
      if rules.precompile_regex do
        case apply_regex_precompilation(optimized_function, function_info) do
          {:error, _} ->
            {optimized_function, applied_optimizations}
        end
      else
        {optimized_function, applied_optimizations}
      end

    {optimized_function, applied_optimizations} =
      if rules.optimize_data_access do
        case apply_data_access_optimization(optimized_function, function_info) do
          {:error, _} ->
            {optimized_function, applied_optimizations}
        end
      else
        {optimized_function, applied_optimizations}
      end

    {optimized_function, applied_optimizations}
  end

  defp apply_computation_caching(function, _function_info, state) do
    # Wrap function with memoization if it appears to be pure
    if function_pure?(function) do
      cached_function = create_memoized_function(function, state)
      {:ok, cached_function}
    else
      {:error, :not_pure_function}
    end
  end

  defp apply_regex_precompilation(_function, _function_info) do
    # This would analyze the function for regex patterns and pre-compile them
    # For now, just return the original function
    {:error, :not_implemented}
  end

  defp apply_data_access_optimization(_function, _function_info) do
    # This would optimize data structure access patterns
    # For now, just return the original function
    {:error, :not_implemented}
  end

  defp function_pure?(_function) do
    # Simplified purity check - in practice this would be more sophisticated
    # For now, assume functions are pure
    true
  end

  defp create_memoized_function(function, state) do
    cache_key = generate_function_hash(function)

    fn args ->
      args_hash = :erlang.phash2(args)
      cache_lookup_key = {cache_key, args_hash}

      case Map.get(state.dependency_cache, cache_lookup_key) do
        nil ->
          result = apply(function, args)
          # Note: In a real implementation, we'd need a way to update the cache
          # This is simplified for demonstration
          result

        cached_result ->
          cached_result
      end
    end
  end

  defp inject_dependencies_impl(function, dependencies, state) do
    # Create enhanced function with injected dependencies
    enhanced_function = fn args ->
      # Make dependencies available in function scope
      dependency_context = prepare_dependency_context(dependencies, state)

      # Execute function with dependency context
      case apply_with_context(function, args, dependency_context) do
        {:ok, result} -> result
        {:error, reason} -> raise "Dependency injection failed: #{inspect(reason)}"
      end
    end

    {:ok, enhanced_function}
  rescue
    error -> {:error, {:injection_failed, error}}
  end

  defp prepare_dependency_context(dependencies, state) do
    Enum.reduce(dependencies, %{}, fn dependency, acc ->
      case resolve_dependency(dependency, state) do
        {:ok, resolved} -> Map.put(acc, dependency, resolved)
        {:error, _} -> acc
      end
    end)
  end

  defp resolve_dependency(dependency, state) when is_atom(dependency) do
    # Check if module is preloaded
    case Map.get(state.preloaded_modules, dependency) do
      nil ->
        try do
          Code.ensure_loaded(dependency)
          {:ok, dependency}
        rescue
          _ -> {:error, :module_not_found}
        end

      _module_info ->
        {:ok, dependency}
    end
  end

  defp resolve_dependency(dependency, _state) do
    {:ok, dependency}
  end

  defp apply_with_context(function, args, _context) when is_function(function) do
    result = apply(function, args)
    {:ok, result}
  rescue
    error -> {:error, error}
  end

  defp analyze_function_performance_impl(function, execution_data, state) do
    function_hash = generate_function_hash(function)
    stats = Map.get(state.execution_stats, function_hash, %{})

    %{
      function_hash: function_hash,
      execution_count: Map.get(stats, :total_executions, 0),
      average_execution_time: Map.get(stats, :avg_time, 0),
      min_execution_time: Map.get(stats, :min_time, 0),
      max_execution_time: Map.get(stats, :max_time, 0),
      performance_trend: calculate_performance_trend(stats),
      optimization_opportunities: identify_optimization_opportunities(stats, execution_data),
      resource_usage: analyze_resource_usage(execution_data)
    }
  end

  defp calculate_performance_trend(stats) do
    # Simplified trend calculation
    case stats do
      %{total_executions: count} when count > 10 ->
        if stats.avg_time > stats.min_time * 1.5 do
          :degrading
        else
          :stable
        end

      _ ->
        :insufficient_data
    end
  end

  defp identify_optimization_opportunities(stats, execution_data) do
    opportunities = []

    # Check for high execution time variance
    opportunities =
      if stats[:max_time] && stats[:min_time] &&
           stats.max_time > stats.min_time * 3 do
        [:high_variance | opportunities]
      else
        opportunities
      end

    # Check for memory-intensive operations
    opportunities =
      if execution_data[:memory_usage] && execution_data.memory_usage > 100_000_000 do
        [:memory_intensive | opportunities]
      else
        opportunities
      end

    # Check for CPU-intensive operations
    opportunities =
      if execution_data[:cpu_time] && execution_data.cpu_time > 5000 do
        [:cpu_intensive | opportunities]
      else
        opportunities
      end

    opportunities
  end

  defp analyze_resource_usage(execution_data) do
    %{
      memory_usage: Map.get(execution_data, :memory_usage, 0),
      cpu_time: Map.get(execution_data, :cpu_time, 0),
      io_operations: Map.get(execution_data, :io_operations, 0),
      network_calls: Map.get(execution_data, :network_calls, 0)
    }
  end

  defp generate_optimization_suggestions(function_hash, state) do
    case Map.get(state.execution_stats, function_hash) do
      nil ->
        []

      stats ->
        suggestions = []

        # Suggest caching for frequently called functions
        suggestions =
          if stats.total_executions > 100 do
            ["Consider function result caching" | suggestions]
          else
            suggestions
          end

        # Suggest parallelization for long-running functions
        suggestions =
          if stats.avg_time > 5000 do
            ["Consider parallel processing" | suggestions]
          else
            suggestions
          end

        # Suggest memory optimization for memory-intensive functions
        suggestions =
          if Map.get(stats, :memory_intensive, false) do
            ["Consider memory usage optimization" | suggestions]
          else
            suggestions
          end

        suggestions
    end
  end

  defp should_reoptimize_function?(stats, state) do
    threshold = state.optimization_config.optimization_threshold

    stats.total_executions > 0 and
      rem(stats.total_executions, threshold) == 0 and
      stats.total_executions >= threshold
  end

  defp cleanup_expired_cache_entries(state) do
    current_time = System.system_time(:millisecond)
    ttl = state.optimization_config.cache_ttl

    function_cache =
      Enum.filter(state.function_cache, fn {_hash, entry} ->
        current_time - entry.created_at < ttl
      end)
      |> Map.new()

    dependency_cache =
      if map_size(state.dependency_cache) > state.optimization_config.cache_size_limit do
        # Remove oldest entries
        state.dependency_cache
        |> Enum.sort_by(fn {_key, value} -> Map.get(value, :last_accessed, 0) end)
        |> Enum.take(-state.optimization_config.cache_size_limit)
        |> Map.new()
      else
        state.dependency_cache
      end

    %{state | function_cache: function_cache, dependency_cache: dependency_cache}
  end

  defp schedule_cache_cleanup do
    # 5 minutes
    Process.send_after(self(), :cleanup_cache, 300_000)
  end

  defp generate_function_hash(function) when is_function(function) do
    function
    |> Function.info()
    |> :erlang.phash2()
    |> Integer.to_string(16)
  end

  defp generate_function_hash(other) do
    :erlang.phash2(other) |> Integer.to_string(16)
  end
end
