# 🔧 Configuration Guide: FLAME Apple Containers Backend

This guide shows how to configure the FLAME Apple Containers backend for different use cases, from minimal FLAME-only setups to full-featured deployments with web dashboards.

## 🚀 Quick Configuration Options

### Environment Variables (Easiest)

Control the backend with environment variables:

```bash
# Core system toggles
export FLAME_ENVIRONMENT=production
export FLAME_ENABLE_METRICS=true
export FLAME_ENABLE_SECURITY=true
export FLAME_ENABLE_RESOURCE_MANAGEMENT=true
export FLAME_ENABLE_ORCHESTRATION=false
export FLAME_ENABLE_OPTIMIZATION=false

# Optional features
export FLAME_ENABLE_WEB_INTERFACE=false
export FLAME_ENABLE_BENCHMARKS=false
export FLAME_MINIMAL_MODE=true

# Web configuration (if enabled)
export FLAME_WEB_PORT=4000
export FLAME_WORKER_PORT=8080
```

### Application Configuration

Or configure in your `config/config.exs`:

```elixir
config :flame_apple_container_backend,
  environment: :production,
  enable_metrics: true,
  enable_security: true,
  enable_resource_management: true,
  enable_orchestration: false,
  enable_optimization: false,
  enable_web_interface: false,
  enable_benchmarks: false,
  minimal_mode: true
```

## 🎯 Use Case Configurations

### 1. Minimal FLAME Backend (Core Only)

**Use case**: Just want FLAME with Apple Containers, no extras.

```elixir
# mix.exs - minimal dependencies
defp deps do
  [
    {:flame, "~> 0.1.0"},
    {:flame_apple_container_backend, "~> 1.0"}
    # No optional dependencies needed
  ]
end

# config/config.exs
config :flame_apple_container_backend,
  minimal_mode: true,
  enable_metrics: false,
  enable_security: false,
  enable_resource_management: false,
  enable_orchestration: false,
  enable_optimization: false,
  enable_web_interface: false

# Usage in your app
{FLAME.Pool, [
  name: MyApp.Pool,
  backend: {FLAME.AppleContainersBackend, [
    image: "my-worker:latest",
    dns_domain: "compute.local",
    mode: :production
  ]}
]}
```

**Environment variables:**
```bash
export FLAME_MINIMAL_MODE=true
export FLAME_ENABLE_METRICS=false
export FLAME_ENABLE_SECURITY=false
export FLAME_ENABLE_RESOURCE_MANAGEMENT=false
export FLAME_ENABLE_ORCHESTRATION=false
export FLAME_ENABLE_OPTIMIZATION=false
export FLAME_ENABLE_WEB_INTERFACE=false
```

### 2. Production Backend with Monitoring

**Use case**: Production deployment with monitoring but no web interface.

```elixir
# mix.exs
defp deps do
  [
    {:flame, "~> 0.1.0"},
    {:flame_apple_container_backend, "~> 1.0"},
    {:telemetry_metrics, "~> 0.6"},
    {:prometheus_ex, "~> 3.0"}  # If using Prometheus
  ]
end

# config/config.exs
config :flame_apple_container_backend,
  environment: :production,
  enable_metrics: true,
  enable_security: true,
  enable_resource_management: true,
  enable_orchestration: false,
  enable_optimization: false,
  enable_web_interface: false

# config/prod.exs
config :flame_apple_container_backend,
  enable_metrics: true,
  enable_security: true

config :flame_apple_container_backend, FLAME.SecurityManager,
  sandbox_enabled: true,
  audit_enabled: true,
  max_execution_time: 300_000

config :flame_apple_container_backend, FLAME.ResourceManager,
  global_limits: %{
    max_total_memory_gb: 16,
    max_total_cpu_cores: 8,
    max_concurrent_containers: 100
  }
```

**Environment variables:**
```bash
export FLAME_ENVIRONMENT=production
export FLAME_ENABLE_METRICS=true
export FLAME_ENABLE_SECURITY=true
export FLAME_ENABLE_RESOURCE_MANAGEMENT=true
```

### 3. Development with Web Dashboard

**Use case**: Development environment with full web dashboard.

```elixir
# mix.exs
defp deps do
  [
    {:flame, "~> 0.1.0"},
    {:flame_apple_container_backend, "~> 1.0"},
    
    # Web dependencies
    {:phoenix, "~> 1.7.0"},
    {:phoenix_live_view, "~> 0.20.0"},
    {:phoenix_html, "~> 3.3"},
    {:plug_cowboy, "~> 2.6"},
    
    # Monitoring
    {:telemetry_metrics, "~> 0.6"},
    {:prometheus_ex, "~> 3.0"}
  ]
end

# config/dev.exs
config :flame_apple_container_backend,
  environment: :development,
  enable_web_interface: true,
  enable_benchmarks: true,
  enable_metrics: true,
  enable_security: true,
  web_port: 4000

config :flame_apple_container_backend, FlameWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: "your-secret-key-base",
  live_view: [signing_salt: "your-signing-salt"],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  watchers: []

# In your application.ex, the web interface will start automatically
```

**Environment variables:**
```bash
export FLAME_ENVIRONMENT=development
export FLAME_ENABLE_WEB_INTERFACE=true
export FLAME_ENABLE_BENCHMARKS=true
export FLAME_WEB_PORT=4000
```

### 4. Full-Featured Enterprise Setup

**Use case**: All features enabled for comprehensive enterprise deployment.

```elixir
# mix.exs - all dependencies
defp deps do
  [
    {:flame, "~> 0.1.0"},
    {:flame_apple_container_backend, "~> 1.0"},
    
    # Web interface
    {:phoenix, "~> 1.7.0"},
    {:phoenix_live_view, "~> 0.20.0"},
    {:phoenix_html, "~> 3.3"},
    {:phoenix_live_dashboard, "~> 0.8"},
    {:plug_cowboy, "~> 2.6"},
    
    # Monitoring and metrics
    {:telemetry_metrics, "~> 0.6"},
    {:telemetry_poller, "~> 1.0"},
    {:prometheus_ex, "~> 3.0"},
    
    # Advanced features
    {:circuit_breaker, "~> 0.5.0"},
    {:gen_state_machine, "~> 3.0"}
  ]
end

# config/config.exs
config :flame_apple_container_backend,
  # All features enabled
  enable_metrics: true,
  enable_security: true,
  enable_resource_management: true,
  enable_orchestration: true,
  enable_optimization: true,
  enable_web_interface: true

# Detailed security configuration
config :flame_apple_container_backend, FLAME.SecurityManager,
  sandbox_enabled: true,
  audit_enabled: true,
  max_execution_time: 600_000,
  max_memory_mb: 2048,
  audit_log_file: "/var/log/myapp/flame_audit.log"

# Resource management
config :flame_apple_container_backend, FLAME.ResourceManager,
  global_limits: %{
    max_total_memory_gb: 32,
    max_total_cpu_cores: 16,
    max_concurrent_containers: 200
  },
  scaling_config: %{
    scale_up_threshold: 0.8,
    scale_down_threshold: 0.3,
    min_containers: 5,
    max_containers: 50
  }

# Web interface
config :flame_apple_container_backend, FlameWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  secret_key_base: System.get_env("SECRET_KEY_BASE"),
  live_view: [signing_salt: System.get_env("LIVE_VIEW_SALT")]
```

### 5. Custom Module Selection

**Use case**: Enable only specific modules you need.

```elixir
# Environment variables for granular control
export FLAME_ENABLE_METRICS=true           # Core metrics only
export FLAME_ENABLE_SECURITY=false         # Skip security features
export FLAME_ENABLE_RESOURCE_MANAGEMENT=true  # Resource tracking
export FLAME_ENABLE_ORCHESTRATION=false    # Skip orchestration
export FLAME_ENABLE_OPTIMIZATION=true      # Function optimization
export FLAME_ENABLE_WEB_INTERFACE=false    # No web UI

# Or in config
config :flame_apple_container_backend,
  enable_metrics: true,
  enable_security: false,
  enable_resource_management: true,
  enable_orchestration: false,
  enable_optimization: true,
  enable_web_interface: false
```

## 🏗️ Integration Examples

### Basic Integration (Minimal)

```elixir
# In your existing Phoenix/Elixir app
# mix.exs
defp deps do
  [
    # Your existing deps...
    {:flame, "~> 0.1.0"},
    {:flame_apple_container_backend, "~> 1.0"}
  ]
end

# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    # Your existing children...
    MyApp.Repo,
    MyAppWeb.Endpoint,
    
    # Add FLAME pool
    {FLAME.Pool, [
      name: MyApp.ComputePool,
      backend: {FLAME.AppleContainersBackend, [
        image: "my-app-worker:latest",
        dns_domain: "compute.local"
      ]}
    ]}
  ]
  # ...
end

# Usage
defmodule MyApp.HeavyWork do
  def process(data) do
    FLAME.call(MyApp.ComputePool, fn ->
      # Your heavy computation
      expensive_computation(data)
    end)
  end
end
```

### With Monitoring Integration

```elixir
# config/config.exs
config :flame_apple_container_backend,
  enable_metrics: true

# Set up telemetry in your app
defmodule MyApp.Telemetry do
  def setup do
    :telemetry.attach_many(
      "my-app-flame-metrics",
      [
        [:flame, :task, :complete],
        [:flame, :container, :provision]
      ],
      &handle_flame_event/4,
      %{}
    )
  end
  
  def handle_flame_event([:flame, :task, :complete], measurements, metadata, _) do
    # Send to your monitoring system
    MyApp.Metrics.histogram("flame.task.duration", measurements.execution_time)
  end
end
```

### Docker Environment Configuration

```dockerfile
# Dockerfile
FROM elixir:1.15-alpine

# Set FLAME configuration via environment
ENV FLAME_ENVIRONMENT=production
ENV FLAME_ENABLE_METRICS=true
ENV FLAME_ENABLE_SECURITY=true
ENV FLAME_ENABLE_RESOURCE_MANAGEMENT=true
ENV FLAME_ENABLE_WEB_INTERFACE=false

# Your app setup...
COPY . .
RUN mix deps.get && mix compile

CMD ["mix", "run", "--no-halt"]
```

```yaml
# docker-compose.yml
version: '3.8'
services:
  app:
    build: .
    environment:
      - FLAME_ENVIRONMENT=production
      - FLAME_ENABLE_METRICS=true
      - FLAME_ENABLE_SECURITY=true
      - FLAME_ENABLE_WEB_INTERFACE=false
      - FLAME_MINIMAL_MODE=false
    ports:
      - "4000:4000"
  
  app-with-dashboard:
    build: .
    environment:
      - FLAME_ENVIRONMENT=development
      - FLAME_ENABLE_WEB_INTERFACE=true
      - FLAME_WEB_PORT=4001
    ports:
      - "4001:4001"
```

### Kubernetes Configuration

```yaml
# k8s-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 3
  template:
    spec:
      containers:
      - name: app
        image: my-app:latest
        env:
        - name: FLAME_ENVIRONMENT
          value: "production"
        - name: FLAME_ENABLE_METRICS
          value: "true"
        - name: FLAME_ENABLE_SECURITY
          value: "true"
        - name: FLAME_ENABLE_WEB_INTERFACE
          value: "false"
        - name: FLAME_MINIMAL_MODE
          value: "false"

---
# Optional: Dashboard deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flame-dashboard
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: dashboard
        image: my-app:latest
        env:
        - name: FLAME_ENVIRONMENT
          value: "production"
        - name: FLAME_ENABLE_WEB_INTERFACE
          value: "true"
        - name: FLAME_WEB_PORT
          value: "4000"
        ports:
        - containerPort: 4000
```

## 🔍 Configuration Validation

Check your configuration:

```elixir
# In IEx or your app
defmodule ConfigChecker do
  def validate_config do
    config = Application.get_all_env(:flame_apple_container_backend)
    
    IO.puts("🔧 FLAME Backend Configuration:")
    IO.puts("================================")
    
    # Check core systems
    systems = [
      {:enable_metrics, "Metrics Collection"},
      {:enable_security, "Security Manager"},
      {:enable_resource_management, "Resource Management"},
      {:enable_orchestration, "Container Orchestration"},
      {:enable_optimization, "Function Optimization"},
      {:enable_web_interface, "Web Dashboard"},
      {:minimal_mode, "Minimal Mode"}
    ]
    
    Enum.each(systems, fn {key, name} ->
      status = if Keyword.get(config, key, false), do: "✅ ENABLED", else: "❌ DISABLED"
      IO.puts("#{name}: #{status}")
    end)
    
    # Check running processes
    IO.puts("\n🔍 Running Processes:")
    IO.puts("====================")
    
    processes = [
      {FLAME.ContainerPool, "Container Pool"},
      {FLAME.ContainerMetrics, "Metrics Collector"},
      {FLAME.SecurityManager, "Security Manager"},
      {FLAME.ResourceManager, "Resource Manager"},
      {FLAME.Orchestrator, "Orchestrator"},
      {FlameWeb.Endpoint, "Web Interface"}
    ]
    
    Enum.each(processes, fn {module, name} ->
      status = case Process.whereis(module) do
        nil -> "❌ NOT RUNNING"
        pid when is_pid(pid) -> "✅ RUNNING (#{inspect(pid)})"
      end
      IO.puts("#{name}: #{status}")
    end)
  end
end

# Run validation
ConfigChecker.validate_config()
```

## 🚀 Quick Start Commands

### Minimal Setup
```bash
# Environment variables only
export FLAME_MINIMAL_MODE=true
export FLAME_ENABLE_WEB_INTERFACE=false

# Start your app
iex -S mix
```

### Development with Dashboard
```bash
# Enable web interface
export FLAME_ENABLE_WEB_INTERFACE=true
export FLAME_ENABLE_BENCHMARKS=true
export FLAME_WEB_PORT=4000

# Start and visit dashboard
iex -S mix
# Open http://localhost:4000/dashboard
```

### Production Monitoring
```bash
# Production settings
export FLAME_ENVIRONMENT=production
export FLAME_ENABLE_METRICS=true
export FLAME_ENABLE_SECURITY=true
export FLAME_ENABLE_RESOURCE_MANAGEMENT=true

# Start with monitoring
mix run --no-halt
```

This flexible configuration system allows you to use exactly the features you need, from a minimal FLAME backend to a full-featured enterprise deployment with web dashboards and comprehensive monitoring.