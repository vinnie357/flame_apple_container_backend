# 📦 FLAME Apple Containers Backend - Integration Guide

This guide shows how to integrate the FLAME Apple Containers backend as a dependency in your Elixir projects.

## 🚀 Quick Integration

### Step 1: Add as Dependency

Add to your `mix.exs`:

```elixir
defp deps do
  [
    # Your existing dependencies...
    {:flame, "~> 0.1.0"},
    {:flame_apple_container_backend, path: "/path/to/flame_apple_container_backend"},
    # Or from hex when published:
    # {:flame_apple_container_backend, "~> 1.0"}
  ]
end
```

### Step 2: Configure in your Application

Add to your `config/config.exs`:

```elixir
# Configure the FLAME backend
config :my_app, :flame_pool,
  name: MyApp.ComputePool,
  backend: {FLAME.AppleContainersBackend, [
    image: "my-app-worker:latest",
    dns_domain: "compute.local", 
    container_prefix: "my-app-worker",
    erlang_cookie: System.get_env("ERLANG_COOKIE", "my-app-cookie"),
    mode: :production,
    pool_config: %{
      min_warm_containers: 3,
      max_warm_containers: 10,
      max_active_containers: 50
    },
    monitoring_config: %{
      telemetry: %{enabled: true},
      prometheus: %{enabled: true}
    }
  ]}

# Optional: Configure individual systems
config :flame_apple_container_backend, FLAME.SecurityManager,
  sandbox_enabled: true,
  audit_enabled: true,
  max_execution_time: 300_000,
  allowed_modules: [
    :erlang, :elixir, Enum, Stream, Map, List, String, Regex,
    Jason, MyApp.CustomHelpers  # Your app-specific modules
  ]

config :flame_apple_container_backend, FLAME.ResourceManager,
  global_limits: %{
    max_total_memory_gb: 16,
    max_total_cpu_cores: 8,
    max_concurrent_containers: 100
  }
```

### Step 3: Add to Application Supervision Tree

In your `lib/my_app/application.ex`:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Your existing children...
      MyApp.Repo,
      MyAppWeb.Endpoint,
      
      # Add FLAME pool with Apple Containers backend
      {FLAME.Pool, Application.get_env(:my_app, :flame_pool)},
      
      # Optional: Add monitoring dashboard
      {MyApp.FlameDashboard, []}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

## 🎯 Usage Examples

### Basic Task Execution

```elixir
defmodule MyApp.HeavyComputation do
  def process_data(large_dataset) do
    # Execute on remote container with full production features
    FLAME.call(MyApp.ComputePool, fn ->
      large_dataset
      |> Enum.map(&complex_transformation/1)
      |> Enum.reduce(&merge_results/2)
    end)
  end
  
  defp complex_transformation(data) do
    # CPU-intensive work happens in isolated container
    # with resource monitoring and security controls
    data
    |> process_with_ml_model()
    |> apply_business_rules()
  end
end
```

### Phoenix LiveView Integration

```elixir
defmodule MyAppWeb.ComputeLive do
  use MyAppWeb, :live_view
  
  def mount(_params, _session, socket) do
    # Subscribe to FLAME metrics for real-time updates
    :telemetry.attach(
      "compute-live-metrics",
      [:flame, :task, :complete],
      &handle_task_completion/4,
      %{live_view_pid: self()}
    )
    
    {:ok, assign(socket, :tasks, [])}
  end
  
  def handle_event("start_computation", %{"data" => data}, socket) do
    task_id = "computation-#{System.unique_integer()}"
    
    # Execute with full monitoring and security
    task = Task.async(fn ->
      FLAME.call(MyApp.ComputePool, fn ->
        MyApp.HeavyComputation.process_data(data)
      end, timeout: 60_000)
    end)
    
    tasks = [{task_id, task} | socket.assigns.tasks]
    {:noreply, assign(socket, :tasks, tasks)}
  end
  
  defp handle_task_completion(event, measurements, metadata, config) do
    send(config.live_view_pid, {:task_completed, metadata.task_id, measurements})
  end
end
```

### Background Job Processing

```elixir
defmodule MyApp.Workers.DataProcessor do
  use Oban.Worker, queue: :heavy_compute
  
  def perform(%Oban.Job{args: %{"dataset_id" => dataset_id}}) do
    dataset = MyApp.Data.get_dataset!(dataset_id)
    
    # Process in isolated container with full monitoring
    result = FLAME.call(MyApp.ComputePool, fn ->
      MyApp.DataProcessing.analyze_dataset(dataset)
    end, timeout: 600_000)  # 10 minute timeout
    
    MyApp.Data.store_analysis_result(dataset_id, result)
    :ok
  end
end
```

### Machine Learning Pipeline

```elixir
defmodule MyApp.ML.TrainingPipeline do
  def train_model(training_data, model_config) do
    # Use orchestrator for multi-step ML pipeline
    cluster_spec = %{
      name: "ml-training-cluster",
      size: 4,  # 4 containers for parallel training
      resource_requirements: %{
        memory_mb: 2048,
        cpu_percent: 90
      },
      timeout: 3_600_000  # 1 hour
    }
    
    {:ok, cluster_id} = FLAME.Orchestrator.create_cluster(cluster_spec)
    
    try do
      # Multi-step workflow
      workflow = %{
        name: "ml-training-pipeline",
        steps: [
          %{
            function: &preprocess_data/1,
            args: [training_data]
          },
          %{
            function: &train_model_step/2,
            args: [model_config],
            depends_on: [0]  # Depends on preprocessing
          },
          %{
            function: &validate_model/1,
            depends_on: [1]  # Depends on training
          },
          %{
            function: &save_model/2,
            args: [model_config.save_path],
            depends_on: [2]  # Depends on validation
          }
        ]
      }
      
      {:ok, workflow_id} = FLAME.Orchestrator.schedule_workflow(workflow)
      
      # Monitor workflow progress
      monitor_workflow_progress(workflow_id)
      
    after
      FLAME.Orchestrator.destroy_cluster(cluster_id)
    end
  end
  
  defp monitor_workflow_progress(workflow_id) do
    # Implementation for monitoring workflow
    # Can integrate with your existing monitoring systems
  end
end
```

## 🛠️ Advanced Configuration

### Environment-Specific Configuration

```elixir
# config/dev.exs
import Config

config :my_app, :flame_pool,
  backend: {FLAME.AppleContainersBackend, [
    mode: :development,
    pool_config: %{
      min_warm_containers: 1,
      max_warm_containers: 3
    },
    monitoring_config: %{
      collection_interval: 10_000
    }
  ]}

# config/prod.exs  
import Config

config :my_app, :flame_pool,
  backend: {FLAME.AppleContainersBackend, [
    image: System.get_env("FLAME_WORKER_IMAGE", "my-app-worker:latest"),
    dns_domain: System.get_env("FLAME_DNS_DOMAIN", "prod.compute.local"),
    mode: :production,
    pool_config: %{
      min_warm_containers: 5,
      max_warm_containers: 20,
      max_active_containers: 100
    },
    circuit_breaker_config: %{
      failure_threshold: 5,
      timeout: 120_000
    },
    monitoring_config: %{
      telemetry: %{enabled: true},
      prometheus: %{enabled: true}
    }
  ]}
```

### Custom Security Policies

```elixir
# config/config.exs
config :flame_apple_container_backend, FLAME.SecurityManager,
  allowed_modules: [
    # Standard Elixir modules
    :erlang, :elixir, Enum, Stream, Map, List, String, Regex,
    
    # Your application modules
    MyApp.Utils,
    MyApp.BusinessLogic,
    MyApp.DataHelpers,
    
    # Third-party libraries you trust
    Jason, HTTPoison, Ecto.Query
  ],
  restricted_functions: [
    # File system access
    {File, :*},
    {:file, :*},
    
    # Network access (unless specifically needed)
    {:gen_tcp, :*},
    {:gen_udp, :*},
    
    # System commands
    {System, :cmd},
    {:os, :cmd},
    
    # Your app-specific restrictions
    {MyApp.DangerousModule, :*}
  ],
  max_execution_time: 600_000,  # 10 minutes for long ML jobs
  max_memory_mb: 2048,          # 2GB for data processing
  audit_log_file: "/var/log/my_app/flame_audit.log"
```

## 📊 Monitoring Integration

### Telemetry Integration

```elixir
defmodule MyApp.FlameMonitoring do
  def attach_telemetry_handlers do
    :telemetry.attach_many(
      "my-app-flame-monitoring",
      [
        [:flame, :container, :provision],
        [:flame, :container, :terminate], 
        [:flame, :task, :execute],
        [:flame, :task, :complete],
        [:flame, :task, :error]
      ],
      &handle_flame_event/4,
      %{}
    )
  end
  
  def handle_flame_event(event_name, measurements, metadata, _config) do
    # Send to your monitoring system
    case event_name do
      [:flame, :task, :complete] ->
        MyApp.Metrics.increment("flame.tasks.completed")
        MyApp.Metrics.histogram("flame.task.duration", measurements.execution_time)
        
      [:flame, :task, :error] ->
        MyApp.Metrics.increment("flame.tasks.failed")
        MyApp.Logger.error("FLAME task failed", metadata)
        
      [:flame, :container, :provision] ->
        MyApp.Metrics.increment("flame.containers.provisioned")
        
      _ ->
        :ok
    end
  end
end

# In your application.ex
def start(_type, _args) do
  # Start telemetry monitoring
  MyApp.FlameMonitoring.attach_telemetry_handlers()
  
  # ... rest of supervision tree
end
```

### Prometheus Metrics Export

```elixir
defmodule MyAppWeb.MetricsController do
  use MyAppWeb, :controller
  
  def prometheus(conn, _params) do
    case FLAME.ContainerMetrics.export_prometheus_metrics() do
      {:ok, metrics_text} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, metrics_text)
      
      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Metrics not available: #{reason}"})
    end
  end
end

# Add to router.ex
scope "/metrics", MyAppWeb do
  get "/prometheus", MetricsController, :prometheus
end
```

## 🎭 Custom Modules and Helpers

### Application-Specific Backend Configuration

```elixir
defmodule MyApp.FlameConfig do
  def backend_config do
    base_config = [
      image: Application.get_env(:my_app, :flame_worker_image),
      dns_domain: Application.get_env(:my_app, :flame_dns_domain),
      erlang_cookie: Application.get_env(:my_app, :erlang_cookie),
      mode: Application.get_env(:my_app, :environment, :production)
    ]
    
    # Add environment-specific configuration
    environment_config = case Application.get_env(:my_app, :environment) do
      :production -> production_config()
      :staging -> staging_config()
      :development -> development_config()
      :test -> test_config()
    end
    
    Keyword.merge(base_config, environment_config)
  end
  
  defp production_config do
    [
      pool_config: %{
        min_warm_containers: 5,
        max_warm_containers: 20,
        max_active_containers: 100,
        container_idle_timeout: 600_000
      },
      circuit_breaker_config: %{
        failure_threshold: 5,
        timeout: 120_000
      },
      monitoring_config: %{
        telemetry: %{enabled: true},
        prometheus: %{enabled: true},
        collection_interval: 30_000
      }
    ]
  end
  
  defp development_config do
    [
      pool_config: %{
        min_warm_containers: 1,
        max_warm_containers: 3,
        max_active_containers: 10
      },
      monitoring_config: %{
        collection_interval: 60_000
      }
    ]
  end
  
  defp test_config do
    [
      mode: :test,
      pool_config: %{
        min_warm_containers: 0,
        max_warm_containers: 1
      }
    ]
  end
end

# Use in your supervision tree
{FLAME.Pool, [
  name: MyApp.ComputePool,
  backend: {FLAME.AppleContainersBackend, MyApp.FlameConfig.backend_config()}
]}
```

### Custom Dashboard Integration

```elixir
defmodule MyApp.FlameDashboard do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def init(_opts) do
    # Subscribe to FLAME events
    :telemetry.attach_many(
      "my-app-dashboard",
      [
        [:flame, :container, :provision],
        [:flame, :task, :complete],
        [:flame, :pool, :status]
      ],
      &handle_dashboard_event/4,
      %{}
    )
    
    # Start periodic status broadcasting
    :timer.send_interval(5_000, self(), :broadcast_status)
    
    {:ok, %{}}
  end
  
  def handle_info(:broadcast_status, state) do
    status = %{
      pool_status: FLAME.ContainerPool.get_pool_status(),
      metrics: FLAME.ContainerMetrics.get_metrics_summary(),
      resource_status: FLAME.ResourceManager.get_resource_status(),
      timestamp: System.system_time(:millisecond)
    }
    
    # Broadcast to LiveView or WebSocket clients
    MyAppWeb.Endpoint.broadcast("flame:dashboard", "status_update", status)
    
    {:noreply, state}
  end
  
  defp handle_dashboard_event(event_name, measurements, metadata, _config) do
    # Real-time event broadcasting
    MyAppWeb.Endpoint.broadcast("flame:events", "event", %{
      event: event_name,
      measurements: measurements,
      metadata: metadata,
      timestamp: System.system_time(:millisecond)
    })
  end
end
```

## 🧪 Testing in Your Application

### Test Helpers

```elixir
defmodule MyApp.FlameTestHelpers do
  def with_flame_backend(test_func) do
    # Start FLAME backend in test mode
    {:ok, _} = FLAME.Pool.start_link([
      name: MyApp.TestPool,
      backend: {FLAME.AppleContainersBackend, [
        mode: :test,
        pool_config: %{min_warm_containers: 0, max_warm_containers: 1}
      ]}
    ])
    
    try do
      test_func.()
    after
      FLAME.Pool.stop(MyApp.TestPool)
    end
  end
  
  def mock_flame_execution(result) do
    # Mock FLAME calls for faster testing
    Process.put(:flame_mock_result, result)
  end
end

# In your tests
defmodule MyAppTest do
  use ExUnit.Case
  import MyApp.FlameTestHelpers
  
  test "heavy computation works with FLAME" do
    with_flame_backend(fn ->
      result = MyApp.HeavyComputation.process_data([1, 2, 3, 4, 5])
      assert is_list(result)
    end)
  end
  
  test "computation with mocked FLAME" do
    mock_flame_execution([10, 20, 30])
    
    result = MyApp.HeavyComputation.process_data([1, 2, 3])
    assert result == [10, 20, 30]
  end
end
```

## 📦 Publishing as a Hex Package

To publish your backend for others to use:

### 1. Update mix.exs for Publishing

```elixir
defmodule FlameAppleContainerBackend.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/your-org/flame_apple_container_backend"

  def project do
    [
      app: :flame_apple_container_backend,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      
      # Hex package configuration
      package: package(),
      description: description(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  defp description do
    """
    Production-grade Apple Containers backend for FLAME with advanced 
    monitoring, security, resource management, and orchestration features.
    """
  end

  defp package do
    [
      name: "flame_apple_container_backend",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Documentation" => "https://hexdocs.pm/flame_apple_container_backend"
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "PRODUCTION_FEATURES.md",
        "INTEGRATION_GUIDE.md",
        "INTERACTIVE_DASHBOARD_GUIDE.md"
      ]
    ]
  end
end
```

### 2. Publish to Hex

```bash
# Build docs
mix docs

# Publish to Hex
mix hex.publish
```

Then users can add it as a dependency:

```elixir
{:flame_apple_container_backend, "~> 1.0"}
```

## 🎯 Integration Summary

The FLAME Apple Containers backend is designed to be:

✅ **Drop-in Replacement**: Works with existing FLAME code
✅ **Production Ready**: Full monitoring, security, and resource management
✅ **Configurable**: Environment-specific configuration
✅ **Extensible**: Custom modules and monitoring integration
✅ **Testable**: Test helpers and mocking support
✅ **Observable**: Full telemetry and metrics integration

Simply add it as a dependency, configure it for your environment, and start using FLAME with enterprise-grade Apple Containers support!