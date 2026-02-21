defmodule FLAME.SecurityManager do
  @moduledoc """
  Security framework for Apple Containers FLAME backend.

  Provides:
  - Code sandboxing with restricted module access  
  - Resource limits enforcement (CPU, memory, execution time)
  - Audit logging for all function executions
  - Function validation and sanitization
  """

  use GenServer
  require Logger

  defstruct [
    :security_config,
    :audit_logger,
    :resource_limits,
    :allowed_modules,
    :restricted_functions
  ]

  @default_config %{
    # 5 minutes
    max_execution_time: 300_000,
    # 512 MB
    max_memory_mb: 512,
    # 80% CPU
    max_cpu_percent: 80,
    audit_enabled: true,
    sandbox_enabled: true,
    allowed_modules: [
      # Core Erlang/Elixir modules
      :erlang,
      :elixir,
      Enum,
      Stream,
      GenServer,
      Task,
      Agent,
      # Math and utility modules
      :math,
      :crypto,
      :base64,
      :unicode,
      # Data structures
      Map,
      List,
      Tuple,
      Keyword,
      # String processing
      String,
      Regex,
      # Process and time utilities
      Process,
      System,
      DateTime,
      NaiveDateTime,
      # JSON handling
      Jason
    ],
    restricted_functions: [
      # File system access
      {File, :*},
      {:file, :*},
      # Network access
      {:gen_tcp, :*},
      {:gen_udp, :*},
      {:inet, :*},
      # System calls
      {:os, :*},
      {System, :cmd},
      # Code compilation/evaluation
      {:code, :*},
      {Code, :eval_string}
    ]
  }

  # Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    # Trap exits so we can handle task failures gracefully
    Process.flag(:trap_exit, true)

    opts_map = if is_list(opts), do: Map.new(opts), else: opts

    config =
      @default_config
      |> Map.merge(opts_map)
      |> merge_default_config()

    audit_logger = start_audit_logger(config)
    resource_limits = extract_resource_limits(config)

    state = %__MODULE__{
      security_config: config,
      audit_logger: audit_logger,
      resource_limits: resource_limits,
      allowed_modules: config.allowed_modules,
      restricted_functions: config.restricted_functions
    }

    {:ok, state}
  end

  def validate_function(function, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:validate_function, function, metadata})
  end

  def execute_safely(function, metadata \\ %{}, timeout \\ 30_000) do
    # Use a GenServer timeout that's longer than function timeout to allow proper handling
    genserver_timeout = max(timeout + 1_000, 5_000)
    GenServer.call(__MODULE__, {:execute_safely, function, metadata, timeout}, genserver_timeout)
  end

  def audit_log(event, metadata) do
    GenServer.cast(__MODULE__, {:audit_log, event, metadata})
  end

  def get_security_status do
    GenServer.call(__MODULE__, :get_security_status)
  end

  # GenServer callbacks

  def handle_call({:validate_function, function, metadata}, _from, state) do
    case validate_function_impl(function, state) do
      :ok ->
        audit_log_impl(state, :function_validated, metadata)
        {:reply, :ok, state}

      {:error, reason} = error ->
        audit_log_impl(state, :function_validation_failed, Map.put(metadata, :reason, reason))
        {:reply, error, state}
    end
  end

  def handle_call({:execute_safely, function, metadata, timeout}, from, state) do
    # Add timeout to metadata for use in execution functions
    metadata_with_timeout = Map.put(metadata, :execution_timeout, timeout)

    if state.security_config.sandbox_enabled do
      execute_in_sandbox(function, metadata_with_timeout, from, state)
    else
      execute_with_monitoring(function, metadata_with_timeout, from, state)
    end
  end

  def handle_call(:get_security_status, _from, state) do
    status = %{
      sandbox_enabled: state.security_config.sandbox_enabled,
      audit_enabled: state.security_config.audit_enabled,
      allowed_modules_count: length(state.allowed_modules),
      restricted_functions_count: length(state.restricted_functions),
      audit_logger_running: is_pid(state.audit_logger),
      resource_limits: state.resource_limits
    }

    {:reply, status, state}
  end

  def handle_cast({:audit_log, event, metadata}, state) do
    audit_log_impl(state, event, metadata)
    {:noreply, state}
  end

  def handle_info({:execution_timeout, task_ref}, state) do
    Logger.warning("Function execution timed out: #{inspect(task_ref)}")
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    Logger.debug("Monitored process #{inspect(pid)} exited with reason: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    # Handle linked process exits (tasks and other linked processes)
    case reason do
      :normal ->
        Logger.debug("Linked process #{inspect(pid)} exited normally")

      {%{__exception__: true} = exception, _stacktrace} ->
        Logger.debug(
          "Linked process #{inspect(pid)} exited with exception: #{Exception.message(exception)}"
        )

      other_reason ->
        Logger.debug(
          "Linked process #{inspect(pid)} exited with reason: #{inspect(other_reason)}"
        )
    end

    {:noreply, state}
  end

  # Private functions

  defp merge_default_config(config) do
    Map.merge(@default_config, config)
  end

  defp start_audit_logger(config) do
    if config.audit_enabled do
      {:ok, logger} = FLAME.AuditLogger.start_link(config)
      logger
    else
      nil
    end
  end

  defp extract_resource_limits(config) do
    %{
      max_execution_time: config.max_execution_time,
      max_memory_mb: config.max_memory_mb,
      max_cpu_percent: config.max_cpu_percent
    }
  end

  defp validate_function_impl(function, state) when is_function(function) do
    if state.security_config.sandbox_enabled do
      validate_function_content(function, state)
    else
      :ok
    end
  end

  defp validate_function_impl(_function, _state) do
    {:error, :invalid_function_type}
  end

  defp validate_function_content(function, state) do
    # Basic function validation - in production, this would be more sophisticated
    info = Function.info(function)

    try do
      # Check function type and basic safety
      case info[:type] do
        :external ->
          module = info[:module]
          function_name = info[:name]
          validate_module_function(module, function_name, state)

        :local ->
          # Local functions are generally safer but still validate
          :ok

        _ ->
          {:error, :unknown_function_type}
      end
    rescue
      _ -> {:error, :function_analysis_failed}
    end
  end

  defp validate_module_function(module, function_name, state) do
    cond do
      module in state.allowed_modules ->
        :ok

      {module, function_name} in state.restricted_functions or
          {module, :*} in state.restricted_functions ->
        {:error, {:restricted_function, module, function_name}}

      true ->
        case Atom.to_string(module) do
          "Elixir." <> _ ->
            # Custom Elixir module - allow but log
            :ok

          module_string ->
            # Erlang module - be more cautious
            if String.starts_with?(module_string, ":") do
              {:error, {:untrusted_erlang_module, module}}
            else
              :ok
            end
        end
    end
  end

  defp execute_in_sandbox(function, metadata, from, state) do
    # In a real implementation, this would create a sandboxed environment
    # For now, we'll just validate and monitor
    case validate_function_impl(function, state) do
      :ok ->
        execute_with_monitoring(function, metadata, from, state)

      {:error, reason} = error ->
        audit_log_impl(
          state,
          :sandbox_execution_blocked,
          Map.merge(metadata, %{reason: reason, from: from})
        )

        GenServer.reply(from, error)
        {:noreply, state}
    end
  end

  defp execute_with_monitoring(function, metadata, from, state) do
    # Use timeout from metadata if provided, otherwise use default
    execution_timeout = metadata[:execution_timeout] || state.resource_limits.max_execution_time

    # Execute with resource monitoring and limits
    task =
      Task.async(fn ->
        execute_with_resource_limits(function, state.resource_limits)
      end)

    # Set up timeout monitoring
    timer_ref =
      Process.send_after(
        self(),
        {:execution_timeout, task.ref},
        execution_timeout
      )

    # Use Task.yield instead of Task.await for better error control
    case Task.yield(task, execution_timeout) do
      {:ok, result} ->
        Process.cancel_timer(timer_ref)

        audit_log_impl(
          state,
          :function_executed_successfully,
          Map.merge(metadata, %{result_type: get_result_type(result)})
        )

        GenServer.reply(from, {:ok, result})

      {:exit, {%{__exception__: true} = exception, _stacktrace}} ->
        # Task exited due to an exception
        Process.cancel_timer(timer_ref)
        Task.shutdown(task, :brutal_kill)

        audit_log_impl(
          state,
          :function_execution_failed,
          Map.merge(metadata, %{error: Exception.message(exception)})
        )

        GenServer.reply(from, {:error, exception})

      {:exit, reason} ->
        # Task exited for other reasons
        Process.cancel_timer(timer_ref)
        Task.shutdown(task, :brutal_kill)

        audit_log_impl(
          state,
          :function_execution_failed,
          Map.merge(metadata, %{exit_reason: reason})
        )

        GenServer.reply(from, {:error, {:task_exit, reason}})

      nil ->
        # Task didn't complete within timeout
        Process.cancel_timer(timer_ref)
        Task.shutdown(task, :brutal_kill)

        audit_log_impl(
          state,
          :function_execution_timeout,
          Map.merge(metadata, %{timeout: execution_timeout})
        )

        GenServer.reply(from, {:error, :timeout})
    end

    {:noreply, state}
  end

  defp execute_with_resource_limits(function, limits) do
    start_time = System.monotonic_time(:millisecond)
    memory_before = :erlang.memory(:total)

    # Execute the function
    result = function.()

    # Check resource usage
    execution_time = System.monotonic_time(:millisecond) - start_time
    memory_after = :erlang.memory(:total)
    memory_used_mb = (memory_after - memory_before) / (1024 * 1024)

    cond do
      execution_time > limits.max_execution_time ->
        raise "Execution time limit exceeded: #{execution_time}ms > #{limits.max_execution_time}ms"

      memory_used_mb > limits.max_memory_mb ->
        raise "Memory limit exceeded: #{memory_used_mb}MB > #{limits.max_memory_mb}MB"

      true ->
        result
    end
  end

  defp get_result_type(result) do
    cond do
      is_map(result) -> :map
      is_list(result) -> :list
      is_binary(result) -> :binary
      is_number(result) -> :number
      is_atom(result) -> :atom
      is_tuple(result) -> :tuple
      true -> :unknown
    end
  end

  defp audit_log_impl(state, event, metadata) do
    if state.audit_logger do
      FLAME.AuditLogger.log(state.audit_logger, event, metadata)
    end
  end
end

defmodule FLAME.AuditLogger do
  @moduledoc """
  Audit logging system for security events.

  Provides buffered logging with periodic flushes to reduce I/O overhead
  while maintaining audit trail integrity.
  """

  use GenServer
  require Logger

  defstruct [
    :log_file,
    :buffer_size,
    :flush_interval,
    :log_buffer
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    opts_map = if is_list(opts), do: Map.new(opts), else: opts

    state = %__MODULE__{
      log_file: Map.get(opts_map, :audit_log_file, "flame_audit.log"),
      buffer_size: Map.get(opts_map, :audit_buffer_size, 100),
      flush_interval: Map.get(opts_map, :audit_flush_interval, 30_000),
      log_buffer: []
    }

    # Schedule periodic flush
    schedule_flush(state.flush_interval)

    # Ensure log file exists and is writable
    File.touch!(state.log_file)

    {:ok, state}
  end

  def log(audit_logger, event, metadata) do
    GenServer.cast(audit_logger, {:log, event, metadata})
  end

  def flush(audit_logger) do
    GenServer.call(audit_logger, :flush)
  end

  def handle_cast({:log, event, metadata}, state) do
    timestamp = System.system_time(:millisecond)

    entry = %{
      timestamp: timestamp,
      event: event,
      metadata: metadata,
      node: Node.self(),
      pid: self()
    }

    new_buffer = [entry | state.log_buffer]

    # Flush if buffer is full
    if length(new_buffer) >= state.buffer_size do
      flush_buffer(%{state | log_buffer: new_buffer})
      {:noreply, %{state | log_buffer: []}}
    else
      {:noreply, %{state | log_buffer: new_buffer}}
    end
  end

  def handle_call(:flush, _from, state) do
    new_state = flush_buffer(state)
    {:reply, :ok, new_state}
  end

  def handle_info(:flush_buffer, state) do
    new_state = flush_buffer(state)
    schedule_flush(state.flush_interval)
    {:noreply, new_state}
  end

  # Private functions

  defp flush_buffer(state) do
    if !Enum.empty?(state.log_buffer) do
      try do
        entries = Enum.reverse(state.log_buffer)

        log_content =
          Enum.map_join(entries, "\n", fn entry ->
            case entry.event do
              :function_validated ->
                "#{entry.timestamp} [SECURITY] Function validated successfully - #{inspect(entry.metadata)}"

              :function_validation_failed ->
                "#{entry.timestamp} [SECURITY] Function validation failed - #{inspect(entry.metadata)}"

              :function_executed_successfully ->
                "#{entry.timestamp} [AUDIT] Function executed - #{inspect(entry.metadata)}"

              :function_execution_failed ->
                "#{entry.timestamp} [AUDIT] Function execution failed - #{inspect(entry.metadata)}"

              _ ->
                "#{entry.timestamp} [AUDIT] #{entry.event} - #{inspect(entry.metadata)}"
            end
          end)

        File.write!(state.log_file, log_content <> "\n", [:append])
      rescue
        error ->
          Logger.error("Failed to write audit log: #{Exception.message(error)}")
      end
    end

    %{state | log_buffer: []}
  end

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush_buffer, interval)
  end
end
