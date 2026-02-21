defmodule FlameWeb.TestController do
  use Phoenix.Controller, formats: [:html, :json]

  import Plug.Conn

  def run_job(conn, params) do
    job_type = Map.get(params, "type", "simple")
    job_count = String.to_integer(Map.get(params, "count", "1"))

    # Start background jobs
    spawn(fn -> execute_test_jobs(job_type, job_count) end)

    # Handle both API and browser requests
    case get_format(conn) do
      "json" ->
        # API response
        json(conn, %{
          success: true,
          message: "Started #{job_count} #{job_type} jobs",
          job_type: job_type,
          job_count: job_count
        })

      _ ->
        # Browser response with redirect
        conn
        |> put_flash(:info, "Started #{job_count} #{job_type} jobs - check the dashboard!")
        |> redirect(to: "/dashboard")
    end
  end

  def status(conn, _params) do
    status = %{
      pool_status: get_pool_status(),
      metrics: get_metrics_summary(),
      resource_status: get_resource_status(),
      circuit_breaker_status: get_circuit_breaker_status(),
      timestamp: System.system_time(:millisecond)
    }

    json(conn, status)
  end

  def execute(conn, %{"job" => job_params}) do
    case execute_flame_job(job_params) do
      {:ok, result} ->
        json(conn, %{success: true, result: result})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{success: false, error: inspect(reason)})
    end
  end

  # Helper function to normalize job parameters from HTTP requests
  defp normalize_job_params(job_params) when is_map(job_params) do
    # Handle both string keys (from HTTP requests) and atom keys (from internal calls)
    raw_type = job_params["type"] || job_params[:type]
    normalized_type = normalize_job_type(raw_type)

    %{
      id: job_params["id"] || job_params[:id] || "task-#{System.unique_integer()}",
      name: job_params["name"] || job_params[:name] || "Unnamed Job",
      type: normalized_type,
      data: job_params["data"] || job_params[:data] || %{}
    }
  end

  # Handle nil and non-map job parameters
  defp normalize_job_params(_job_params) do
    %{
      id: "task-#{System.unique_integer()}",
      name: "Default Job",
      type: :simple,
      data: %{}
    }
  end

  defp normalize_job_type(type) when is_binary(type) do
    case type do
      "simple" -> :simple
      "complex" -> :complex
      "error" -> :error
      "ml" -> :ml
      "mixed" -> :mixed
      # Default fallback
      _ -> :simple
    end
  end

  defp normalize_job_type(type) when is_atom(type) and type != nil, do: type
  # Explicit nil handling
  defp normalize_job_type(nil), do: :simple
  # Default fallback for any other type
  defp normalize_job_type(_), do: :simple

  # Public functions for dashboard integration

  def execute_test_jobs(job_type, count) do
    IO.puts("🚀 Starting #{count} #{job_type} test jobs...")

    jobs =
      case job_type do
        :simple -> simple_jobs(count)
        :complex -> complex_jobs(count)
        :error -> error_jobs(count)
        :mixed -> mixed_jobs(count)
        :ml -> ml_jobs(count)
        "simple" -> simple_jobs(count)
        "complex" -> complex_jobs(count)
        "error" -> error_jobs(count)
        "mixed" -> mixed_jobs(count)
        "ml" -> ml_jobs(count)
        _ -> simple_jobs(count)
      end

    # Execute jobs with realistic delays
    Enum.with_index(jobs, 1)
    |> Enum.each(fn {job, index} ->
      IO.puts("📋 Executing job #{index}/#{count}: #{job.name}")

      case execute_flame_job(job) do
        {:ok, result} ->
          IO.puts("✅ Job #{index} completed: #{inspect(result)}")

        {:error, reason} ->
          IO.puts("❌ Job #{index} failed: #{inspect(reason)}")
      end

      # Add small delay between jobs for tests
      if index < count, do: Process.sleep(100)
    end)

    IO.puts("🎉 All #{count} jobs completed!")
  end

  defp execute_flame_job(job_params) do
    # Normalize job parameters from HTTP request (string keys) to internal format (atom keys)
    job = normalize_job_params(job_params)
    task_id = job[:id] || "task-#{System.unique_integer()}"

    # Record task start for metrics
    FLAME.ContainerMetrics.record_task_execution(task_id, 0, %{
      started_at: System.system_time(:millisecond),
      job_type: job[:type],
      job_name: job[:name]
    })

    start_time = System.monotonic_time(:millisecond)

    try do
      # Try to use real FLAME pool for execution, fall back to local execution if unavailable
      result =
        try do
          FLAME.call(
            FlameAppleContainerBackend.Pool,
            fn ->
              case job[:type] do
                :simple ->
                  simulate_simple_computation(job[:data])

                :complex ->
                  simulate_complex_computation(job[:data])

                :error ->
                  simulate_error_job(job[:data])

                :ml ->
                  simulate_ml_job_proper(job[:data])
              end
            end,
            timeout: 5000
          )
        catch
          # Fall back to local execution if FLAME is not available (e.g., in tests)
          :exit, _ ->
            case job[:type] do
              :simple ->
                simulate_simple_computation(job[:data])

              :complex ->
                simulate_complex_computation(job[:data])

              :error ->
                simulate_error_job(job[:data])

              :ml ->
                simulate_ml_job_proper(job[:data])
            end
        end

      execution_time = System.monotonic_time(:millisecond) - start_time

      # Record successful completion
      FLAME.ContainerMetrics.record_task_completion(task_id, execution_time, %{
        completed_at: System.system_time(:millisecond),
        result_size: byte_size(inspect(result))
      })

      {:ok, result}
    rescue
      error ->
        _execution_time = System.monotonic_time(:millisecond) - start_time

        # Record error
        FLAME.ContainerMetrics.record_task_error(task_id, error.__struct__, %{
          error_at: System.system_time(:millisecond),
          error_message: Exception.message(error)
        })

        {:error, error}
    end
  end

  defp simple_jobs(count) do
    Enum.map(1..count, fn i ->
      %{
        id: "simple-job-#{i}",
        name: "Simple Math Job #{i}",
        type: :simple,
        data: %{numbers: Enum.to_list(1..(i * 100))}
      }
    end)
  end

  defp complex_jobs(count) do
    Enum.map(1..count, fn i ->
      %{
        id: "complex-job-#{i}",
        name: "Complex Data Processing #{i}",
        type: :complex,
        data: %{
          dataset_size: i * 1000,
          operations: [:sort, :filter, :transform, :aggregate]
        }
      }
    end)
  end

  defp error_jobs(count) do
    Enum.map(1..count, fn i ->
      %{
        id: "error-job-#{i}",
        name: "Error Simulation #{i}",
        type: :error,
        data: %{error_type: Enum.random([:timeout, :memory, :network, :validation])}
      }
    end)
  end

  defp mixed_jobs(count) do
    types = [:simple, :complex, :error, :ml]

    Enum.map(1..count, fn i ->
      type = Enum.at(types, rem(i - 1, length(types)))

      %{
        id: "mixed-job-#{i}",
        name: "Mixed Job #{i} (#{type})",
        type: type,
        data: %{iteration: i, complexity: :rand.uniform(10)}
      }
    end)
  end

  defp ml_jobs(count) do
    Enum.map(1..count, fn i ->
      %{
        id: "ml-job-#{i}",
        name: "ML Training Job #{i}",
        type: :ml,
        data: %{
          model_type:
            Enum.random(["neural_network", "random_forest", "svm", "linear_regression"]),
          dataset_size: i * 5000,
          epochs: :rand.uniform(100) + 50
        }
      }
    end)
  end

  # Simulation functions (replace with real FLAME calls in production)

  defp simulate_simple_computation(data) do
    # Handle both proper simple job data and mixed job data
    numbers =
      case data do
        %{numbers: nums} -> nums
        # Generate numbers for mixed jobs
        %{iteration: i, complexity: _c} -> Enum.to_list(1..(i * 10))
        # Default
        _ -> [1, 2, 3, 4, 5]
      end

    # Fast execution for tests: 10-50ms
    Process.sleep(:rand.uniform(40) + 10)

    # Simulate container provision
    container_id = "sim-container-#{:rand.uniform(999)}"
    FLAME.ContainerMetrics.record_container_provision(container_id)
    FLAME.ContainerMetrics.record_container_checkout(container_id)

    result = %{
      sum: Enum.sum(numbers),
      count: length(numbers),
      average: Enum.sum(numbers) / length(numbers),
      container_id: container_id
    }

    # Simulate container return
    FLAME.ContainerMetrics.record_container_return(container_id)

    result
  end

  defp simulate_complex_computation(data) do
    # Handle both proper complex job data and mixed job data
    {size, ops} =
      case data do
        # Handle atom keys (internal calls)
        %{dataset_size: s, operations: o} -> {s, o}
        # Handle string keys (HTTP requests)
        %{"dataset_size" => s, "operations" => o} -> {s, o}
        # Generate for mixed jobs
        %{iteration: i, complexity: _c} -> {i * 100, [:sort, :filter]}
        # Default
        _ -> {1000, [:sort]}
      end

    # Fast execution for tests: 50-200ms
    Process.sleep(:rand.uniform(150) + 50)

    container_id = "complex-container-#{:rand.uniform(999)}"
    FLAME.ContainerMetrics.record_container_provision(container_id)
    FLAME.ContainerMetrics.record_container_checkout(container_id)

    # Simulate each operation
    results =
      Enum.map(ops, fn op ->
        # Each operation takes time
        Process.sleep(200)
        %{operation: op, result: "processed_#{size}_items"}
      end)

    result = %{
      operations_completed: results,
      dataset_size: size,
      processing_time: :rand.uniform(3000) + 1000,
      container_id: container_id
    }

    FLAME.ContainerMetrics.record_container_return(container_id)
    result
  end

  defp simulate_error_job(data) do
    # Handle both proper error job data and mixed job data
    error_type =
      case data do
        # Handle atom keys (internal calls)
        %{error_type: et} ->
          et

        # Handle string keys (HTTP requests)
        %{"error_type" => et} when is_binary(et) ->
          case et do
            "timeout" -> :timeout
            "memory" -> :memory
            "network" -> :network
            "validation" -> :validation
            _ -> :timeout
          end

        %{"error_type" => et} when is_atom(et) ->
          et

        # Generate for mixed jobs
        %{iteration: _i, complexity: _c} ->
          Enum.random([:timeout, :memory, :network])

        # Default
        _ ->
          :timeout
      end

    # Fast execution for tests: 20-100ms
    Process.sleep(:rand.uniform(80) + 20)

    container_id = "error-container-#{:rand.uniform(999)}"
    FLAME.ContainerMetrics.record_container_provision(container_id)
    FLAME.ContainerMetrics.record_container_checkout(container_id)

    # Trigger circuit breaker occasionally (only if available)
    if :rand.uniform(10) > 7 do
      try do
        FLAME.CircuitBreaker.call(:task_execution, fn ->
          raise "Simulated circuit breaker error"
        end)
      catch
        # Circuit breaker not available, continue
        :exit, _ -> :ok
      end
    end

    case error_type do
      :timeout ->
        raise "Task execution timeout"

      :memory ->
        raise "Memory limit exceeded"

      :network ->
        raise "Network connection failed"

      :validation ->
        raise ArgumentError, "Invalid input data"
    end
  end

  defp simulate_ml_job_proper(data) do
    # Handle both proper ML job data and fallback data
    {model_type, dataset_size, epochs} =
      case data do
        # Handle atom keys (internal calls)
        %{model_type: mt, dataset_size: ds, epochs: e} -> {mt, ds, e}
        # Handle string keys (HTTP requests)
        %{"model_type" => mt, "dataset_size" => ds, "epochs" => e} -> {mt, ds, e}
        %{iteration: i, complexity: c} -> {"neural_network", i * 1000, c * 10}
        # Default values
        _ -> {"neural_network", 1000, 50}
      end

    # Shorter processing time for tests
    # Cap at 100ms for tests
    base_time = min(100, dataset_size / 10000)
    # Max 5 epochs worth
    processing_time = round(base_time + min(epochs, 5) * 2)
    Process.sleep(processing_time)

    container_id = "ml-container-#{:rand.uniform(999)}"
    FLAME.ContainerMetrics.record_container_provision(container_id)
    FLAME.ContainerMetrics.record_container_checkout(container_id)

    # Simulate resource-intensive ML computation
    FLAME.ResourceManager.register_container(container_id, %{
      memory_mb: 1024,
      cpu_percent: 80,
      disk_mb: 2048
    })

    result = %{
      model_type: model_type,
      dataset_size: dataset_size,
      epochs: epochs,
      model_accuracy: :rand.uniform(100) / 100,
      training_iterations: epochs,
      processing_time: processing_time,
      container_id: container_id,
      resource_usage: %{
        peak_memory_mb: :rand.uniform(800) + 200,
        cpu_utilization: :rand.uniform(30) + 60
      }
    }

    FLAME.ContainerMetrics.record_container_return(container_id)
    FLAME.ResourceManager.unregister_container(container_id)

    result
  end

  # Status helper functions

  defp get_pool_status do
    try do
      FLAME.ContainerPool.get_pool_status()
    rescue
      _ -> %{warm_pool_size: 0, active_containers: 0, total_containers: 0}
    catch
      :exit, _ -> %{warm_pool_size: 0, active_containers: 0, total_containers: 0}
    end
  end

  defp get_metrics_summary do
    try do
      FLAME.ContainerMetrics.get_metrics_summary()
    rescue
      _ -> %{total_task_executions: 0, average_execution_time: 0}
    catch
      :exit, _ -> %{total_task_executions: 0, average_execution_time: 0}
    end
  end

  defp get_resource_status do
    try do
      FLAME.ResourceManager.get_resource_status()
    rescue
      _ -> %{utilization_percentage: 0, container_count: 0}
    catch
      :exit, _ -> %{utilization_percentage: 0, container_count: 0}
    end
  end

  defp get_circuit_breaker_status do
    try do
      %{
        task_execution: FLAME.CircuitBreaker.get_state(:task_execution),
        container_provisioning: FLAME.CircuitBreaker.get_state(:container_provisioning),
        container_health: FLAME.CircuitBreaker.get_state(:container_health)
      }
    rescue
      _ ->
        %{
          task_execution: %{state: :unknown},
          container_provisioning: %{state: :unknown},
          container_health: %{state: :unknown}
        }
    catch
      :exit, _ ->
        %{
          task_execution: %{state: :unknown},
          container_provisioning: %{state: :unknown},
          container_health: %{state: :unknown}
        }
    end
  end
end
