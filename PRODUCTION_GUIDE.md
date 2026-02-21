# FLAME Apple Containers Production Deployment Guide

## Overview

This guide covers deploying the FLAME Apple Containers backend in production environments, including security, monitoring, and scaling considerations.

## Architecture

### HTTP-Based Communication
- **Why HTTP over Erlang Distribution**: Apple Containers has networking restrictions that make Erlang distribution unreliable
- **RESTful API**: Simple HTTP endpoints for health checks, info, and function execution
- **JSON Payloads**: All communication uses JSON for cross-platform compatibility

### Container Structure
```
flame-http:latest
├── Elixir 1.15 runtime
├── FLAME dependencies
├── HTTP server (Cowboy/Plug)
├── Health monitoring
└── Function execution engine
```

## Production Deployment

### 1. Container Image Preparation

Build optimized production image:
```bash
# Use the HTTP-based image
container build --tag flame-worker:production --file Dockerfile.http .

# Verify image
container run --name test-prod --rm --env FLAME_WORKER_PORT=4000 flame-worker:production &
sleep 5
curl http://$(container inspect test-prod | grep -o '"Addr": "[^"]*"' | cut -d'"' -f4):4000/health
container stop test-prod
```

### 2. Environment Configuration

Essential environment variables:
```bash
# Worker port (default: 4000)
export FLAME_WORKER_PORT=4000

# Optional: Custom node configuration
export HOME="/root"
export ELIXIR_ERL_OPTIONS="+K true +A 4"
```

### 3. Backend Integration

Update your FLAME backend configuration:
```elixir
# In your application's config
config :my_app, :flame_backend,
  module: FLAME.AppleContainersBackend,
  opts: [
    image: "flame-worker:production",
    dns_domain: "flame.local",
    container_prefix: "prod-worker",
    erlang_cookie: System.get_env("FLAME_ERLANG_COOKIE")
  ]
```

### 4. FLAME Pool Configuration

```elixir
# In your application supervision tree
children = [
  {FLAME.Pool,
   name: MyApp.ComputePool,
   min: 0,
   max: 10,
   boot_timeout: 30_000,
   idle_shutdown_after: 300_000,
   backend: {FLAME.AppleContainersBackend, [
     image: "flame-worker:production",
     dns_domain: "flame.local",
     container_prefix: "compute"
   ]}}
]
```

## Security Considerations

### 1. Container Security
- **Minimal Images**: Use Alpine-based images to reduce attack surface
- **Non-Root Users**: Consider running containers as non-root (if Apple Containers supports it)
- **Resource Limits**: Implement container resource constraints

### 2. Network Security
- **DNS Isolation**: Use dedicated DNS domains for FLAME workers
- **Port Management**: Restrict worker ports to known ranges
- **Firewall Rules**: Limit container network access

### 3. Code Execution Security
```elixir
# Implement sandboxing in your backend
defmodule SecureFLAME do
  def safe_execute(code, timeout \\ 5000) do
    try do
      # Use Code.eval_string with restricted bindings
      {result, _} = Code.eval_string(code, [], [
        file: "secure_eval",
        line: 1
      ])
      {:ok, result}
    rescue
      error -> {:error, inspect(error)}
    catch
      :exit, reason -> {:error, {:exit, reason}}
      :throw, value -> {:error, {:throw, value}}
    after
      # Cleanup resources
    end
  end
end
```

## Monitoring and Observability

### 1. Health Monitoring

Use the built-in health endpoint:
```bash
# Health check script
#!/bin/bash
CONTAINER_IP=$(container inspect $CONTAINER_NAME | grep -o '"Addr": "[^"]*"' | cut -d'"' -f4)
curl -f http://$CONTAINER_IP:4000/health || exit 1
```

### 2. Metrics Collection

Monitor key metrics:
- Container startup times
- Function execution latency
- Memory and CPU usage
- Error rates

### 3. Logging

Configure centralized logging:
```elixir
# In config/runtime.exs
config :logger,
  backends: [:console],
  level: :info

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:container_id, :function_id]
```

### 4. Continuous Monitoring

Use the monitoring script:
```bash
# Monitor all FLAME containers
elixir monitor_containers.exs

# Continuous monitoring
elixir monitor_containers.exs continuous 30
```

## Performance Optimization

### 1. Container Startup Optimization

Reduce cold start times:
- Pre-compile dependencies in Docker image
- Use warm container pools
- Implement container reuse strategies

### 2. Resource Management

```elixir
# Configure appropriate pool settings
{FLAME.Pool,
 name: OptimizedPool,
 min: 2,                    # Keep warm containers
 max: 20,                   # Scale based on load
 boot_timeout: 60_000,      # Allow time for container startup
 idle_shutdown_after: 600_000  # Keep containers alive longer
}
```

### 3. Function Execution Optimization

```elixir
# Batch multiple operations
FLAME.call(pool, fn ->
  # Combine multiple operations in single call
  results = [
    expensive_operation_1(),
    expensive_operation_2(),
    expensive_operation_3()
  ]
  
  process_batch(results)
end)
```

## Scaling and Load Management

### 1. Horizontal Scaling

Scale FLAME pools based on demand:
```elixir
defmodule DynamicScaling do
  def adjust_pool_size(pool_name, target_size) do
    current_size = FLAME.Pool.get_info(pool_name).size
    
    cond do
      target_size > current_size ->
        # Scale up
        for _ <- 1..(target_size - current_size) do
          FLAME.Pool.grow(pool_name)
        end
        
      target_size < current_size ->
        # Scale down
        for _ <- 1..(current_size - target_size) do
          FLAME.Pool.shrink(pool_name)
        end
        
      true ->
        # No change needed
        :ok
    end
  end
end
```

### 2. Load Balancing

Distribute work across multiple pools:
```elixir
defmodule LoadBalancer do
  def execute_distributed(function, pools \\ [:pool1, :pool2, :pool3]) do
    pool = Enum.random(pools)
    FLAME.call(pool, function)
  end
end
```

## Troubleshooting

### Common Issues

1. **Container Startup Failures**
   - Check Apple Containers system status: `container system status`
   - Verify image exists: `container image list`
   - Check logs: `container logs <container_name>`

2. **Network Connectivity Issues**
   - Verify DNS resolution: `nslookup <container>.flame.local`
   - Test HTTP endpoints: `curl http://<container_ip>:4000/health`
   - Check firewall settings

3. **Performance Issues**
   - Monitor container resource usage
   - Check for memory leaks in function execution
   - Optimize pool configurations

### Debug Tools

```bash
# Container debugging
container exec <container_name> ps aux
container exec <container_name> netstat -ln
container exec <container_name> free -h

# HTTP endpoint testing
curl -X POST http://<container_ip>:4000/execute \
  -H "Content-Type: application/json" \
  -d '{"function": "System.schedulers_online()", "args": []}'
```

## Best Practices

1. **Container Management**
   - Use meaningful container names
   - Implement proper cleanup on shutdown
   - Monitor container lifecycle events

2. **Function Design**
   - Keep functions stateless
   - Avoid long-running operations
   - Implement proper error handling

3. **Resource Management**
   - Set appropriate pool limits
   - Monitor memory usage
   - Implement graceful degradation

4. **Security**
   - Validate all function inputs
   - Implement execution timeouts
   - Log security-relevant events

## Maintenance

### Regular Tasks

1. **Image Updates**
   ```bash
   # Update base images regularly
   container build --tag flame-worker:latest --file Dockerfile.http .
   ```

2. **Container Cleanup**
   ```bash
   # Clean up orphaned containers
   container system prune
   ```

3. **Monitoring Review**
   - Review monitoring metrics weekly
   - Update alerting thresholds as needed
   - Analyze performance trends

This guide provides a comprehensive approach to deploying FLAME with Apple Containers in production environments, ensuring security, performance, and reliability.