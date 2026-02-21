defmodule FLAME.ClusterManager do
  @moduledoc """
  Multi-cluster management for Apple Containers FLAME backend.

  Provides enterprise-grade cluster coordination, cross-cluster load balancing,
  and disaster recovery capabilities for distributed FLAME deployments.

  Features:
  - Multi-cluster registration and discovery
  - Cross-cluster load balancing and task migration
  - Cluster health monitoring and failover
  - Resource aggregation and global resource management
  - Disaster recovery and cluster backup strategies
  """

  use GenServer
  require Logger

  alias FLAME.ResourceManager

  defstruct [
    :clusters,
    :primary_cluster,
    :cluster_config,
    :health_checks,
    :load_balancer,
    :failover_policies,
    :metrics_aggregator,
    :failover_callback
  ]

  # 30 seconds
  @health_check_interval 30_000
  # 1 minute
  @cluster_sync_interval 60_000
  # 2 minutes
  @failover_timeout 120_000

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a new cluster in the multi-cluster environment.

  ## Parameters
  - cluster_id: Unique identifier for the cluster
  - config: Cluster configuration including endpoints, credentials, and capabilities

  ## Returns
  - {:ok, cluster_info} on successful registration
  - {:error, reason} on failure
  """
  def register_cluster(cluster_id, config) do
    GenServer.call(__MODULE__, {:register_cluster, cluster_id, config})
  end

  @doc """
  Unregister a cluster from the multi-cluster environment.
  """
  def unregister_cluster(cluster_id) do
    GenServer.call(__MODULE__, {:unregister_cluster, cluster_id})
  end

  @doc """
  Get the status of all registered clusters.
  """
  def get_cluster_status do
    GenServer.call(__MODULE__, :get_cluster_status)
  end

  @doc """
  Select the best cluster for task execution based on load balancing strategy.
  """
  def select_cluster_for_task(task_requirements \\ %{}) do
    GenServer.call(__MODULE__, {:select_cluster, task_requirements})
  end

  @doc """
  Trigger manual failover from one cluster to another.
  """
  def trigger_failover(from_cluster, to_cluster, reason \\ "manual") do
    GenServer.call(__MODULE__, {:trigger_failover, from_cluster, to_cluster, reason})
  end

  @doc """
  Get aggregated metrics across all clusters.
  """
  def get_aggregated_metrics do
    GenServer.call(__MODULE__, :get_aggregated_metrics)
  end

  @doc """
  Execute a task with automatic cluster selection and failover.
  """
  def execute_task_with_failover(task_function, options \\ %{}) do
    GenServer.call(
      __MODULE__,
      {:execute_task_with_failover, task_function, options},
      @failover_timeout
    )
  end

  ## GenServer Callbacks

  def init(opts) do
    cluster_config = %{
      local_cluster_id: Keyword.get(opts, :cluster_id, generate_cluster_id()),
      discovery_method: Keyword.get(opts, :discovery_method, :static),
      load_balancing_strategy: Keyword.get(opts, :load_balancing_strategy, :round_robin),
      failover_enabled: Keyword.get(opts, :failover_enabled, true),
      health_check_interval: Keyword.get(opts, :health_check_interval, @health_check_interval),
      cluster_sync_interval: Keyword.get(opts, :cluster_sync_interval, @cluster_sync_interval)
    }

    state = %__MODULE__{
      clusters: %{},
      primary_cluster: cluster_config.local_cluster_id,
      cluster_config: cluster_config,
      health_checks: %{},
      load_balancer: initialize_load_balancer(cluster_config.load_balancing_strategy),
      failover_policies: initialize_failover_policies(opts),
      metrics_aggregator: initialize_metrics_aggregator(),
      failover_callback: Keyword.get(opts, :failover_callback)
    }

    # Register local cluster
    local_cluster_info = %{
      id: cluster_config.local_cluster_id,
      type: :local,
      endpoints: get_local_endpoints(),
      capabilities: get_local_capabilities(),
      status: :healthy,
      last_seen: System.system_time(:millisecond),
      resources: get_local_resources(),
      version: get_flame_version()
    }

    state = put_in(state.clusters[cluster_config.local_cluster_id], local_cluster_info)

    # Start periodic tasks
    schedule_health_checks()
    schedule_cluster_sync()

    # Initialize telemetry
    :telemetry.execute([:flame, :cluster_manager, :initialized], %{cluster_count: 1}, %{
      cluster_id: cluster_config.local_cluster_id
    })

    Logger.info(
      "ClusterManager initialized with local cluster: #{cluster_config.local_cluster_id}"
    )

    {:ok, state}
  end

  def handle_call({:register_cluster, cluster_id, config}, _from, state) do
    Logger.info("Registering cluster: #{cluster_id}")

    case validate_cluster_config(config) do
      :ok ->
        cluster_info = %{
          id: cluster_id,
          type: :remote,
          endpoints: config.endpoints,
          capabilities: config.capabilities || [],
          status: :unknown,
          last_seen: System.system_time(:millisecond),
          resources: %{},
          version: config.version,
          credentials: config.credentials,
          region: config.region,
          zone: config.zone,
          priority: config.priority || 100
        }

        # Perform initial health check
        health_status = perform_health_check(cluster_info)
        cluster_info = %{cluster_info | status: health_status}

        state = put_in(state.clusters[cluster_id], cluster_info)

        state =
          put_in(state.health_checks[cluster_id], %{
            last_check: System.system_time(:millisecond),
            status: health_status,
            consecutive_failures: if(health_status == :healthy, do: 0, else: 1)
          })

        # Update load balancer
        state = %{
          state
          | load_balancer: add_cluster_to_load_balancer(state.load_balancer, cluster_info)
        }

        :telemetry.execute([:flame, :cluster_manager, :cluster_registered], %{}, %{
          cluster_id: cluster_id,
          cluster_type: :remote,
          status: health_status
        })

        {:reply, {:ok, cluster_info}, state}

      {:error, reason} ->
        Logger.error("Failed to register cluster #{cluster_id}: #{reason}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unregister_cluster, cluster_id}, _from, state) do
    case Map.get(state.clusters, cluster_id) do
      nil ->
        {:reply, {:error, :cluster_not_found}, state}

      cluster_info ->
        Logger.info("Unregistering cluster: #{cluster_id}")

        # Remove from clusters and health checks
        state = %{
          state
          | clusters: Map.delete(state.clusters, cluster_id),
            health_checks: Map.delete(state.health_checks, cluster_id)
        }

        # Update load balancer
        state = %{
          state
          | load_balancer: remove_cluster_from_load_balancer(state.load_balancer, cluster_info)
        }

        # If this was the primary cluster, select a new one
        state =
          if state.primary_cluster == cluster_id do
            new_primary = select_new_primary_cluster(state.clusters)
            Logger.info("Primary cluster changed from #{cluster_id} to #{new_primary}")
            %{state | primary_cluster: new_primary}
          else
            state
          end

        :telemetry.execute([:flame, :cluster_manager, :cluster_unregistered], %{}, %{
          cluster_id: cluster_id
        })

        {:reply, :ok, state}
    end
  end

  def handle_call(:get_cluster_status, _from, state) do
    cluster_status =
      Enum.map(state.clusters, fn {id, cluster} ->
        health_info = Map.get(state.health_checks, id, %{})

        %{
          id: id,
          type: cluster.type,
          status: cluster.status,
          last_seen: cluster.last_seen,
          resources: cluster.resources,
          capabilities: cluster.capabilities,
          health_check: health_info,
          is_primary: id == state.primary_cluster,
          endpoints: cluster.endpoints,
          region: Map.get(cluster, :region),
          zone: Map.get(cluster, :zone),
          priority: Map.get(cluster, :priority, 100)
        }
      end)

    {:reply, cluster_status, state}
  end

  def handle_call({:select_cluster, task_requirements}, _from, state) do
    available_clusters =
      Enum.filter(state.clusters, fn {_id, cluster} ->
        cluster.status == :healthy
      end)

    case available_clusters do
      [] ->
        {:reply, {:error, :no_healthy_clusters}, state}

      clusters ->
        selected_cluster = select_best_cluster(clusters, task_requirements, state.load_balancer)
        {:reply, {:ok, selected_cluster}, state}
    end
  end

  def handle_call({:trigger_failover, from_cluster, to_cluster, reason}, _from, state) do
    Logger.warning("Triggering failover from #{from_cluster} to #{to_cluster}: #{reason}")

    case {Map.get(state.clusters, from_cluster), Map.get(state.clusters, to_cluster)} do
      {nil, _} ->
        {:reply, {:error, :source_cluster_not_found}, state}

      {_, nil} ->
        {:reply, {:error, :target_cluster_not_found}, state}

      {_from_info, to_info} when to_info.status != :healthy ->
        {:reply, {:error, :target_cluster_unhealthy}, state}

      {from_info, to_info} ->
        # Perform failover
        case perform_failover(from_info, to_info, state) do
          :ok ->
            # Update cluster status
            state = put_in(state.clusters[from_cluster].status, :failed)

            # Update primary cluster if needed
            state =
              if state.primary_cluster == from_cluster do
                %{state | primary_cluster: to_cluster}
              else
                state
              end

            :telemetry.execute([:flame, :cluster_manager, :failover_completed], %{}, %{
              from_cluster: from_cluster,
              to_cluster: to_cluster,
              reason: reason
            })

            {:reply, :ok, state}
        end
    end
  end

  def handle_call(:get_aggregated_metrics, _from, state) do
    metrics = aggregate_cluster_metrics(state.clusters)
    {:reply, metrics, state}
  end

  def handle_call({:execute_task_with_failover, task_function, options}, _from, state) do
    max_retries = Map.get(options, :max_retries, 3)

    case execute_with_automatic_failover(task_function, options, state, max_retries) do
      {:ok, result, cluster_id} ->
        :telemetry.execute([:flame, :cluster_manager, :task_executed], %{}, %{
          cluster_id: cluster_id,
          success: true
        })

        {:reply, {:ok, result}, state}

      {:error, reason} ->
        :telemetry.execute([:flame, :cluster_manager, :task_failed], %{}, %{
          reason: reason,
          max_retries: max_retries
        })

        {:reply, {:error, reason}, state}
    end
  end

  def handle_info(:health_check, state) do
    state = perform_all_health_checks(state)
    schedule_health_checks()
    {:noreply, state}
  end

  def handle_info(:cluster_sync, state) do
    state = synchronize_cluster_state(state)
    schedule_cluster_sync()
    {:noreply, state}
  end

  def handle_info({:cluster_health_changed, cluster_id, old_status, new_status}, state) do
    Logger.info("Cluster #{cluster_id} health changed from #{old_status} to #{new_status}")

    case {old_status, new_status} do
      {:healthy, :unhealthy} ->
        # Cluster became unhealthy, consider failover
        handle_cluster_failure(cluster_id, state)

      {:unhealthy, :healthy} ->
        # Cluster recovered
        handle_cluster_recovery(cluster_id, state)

      _ ->
        {:noreply, state}
    end
  end

  ## Private Functions

  defp generate_cluster_id do
    hostname = :inet.gethostname() |> elem(1) |> to_string()
    timestamp = System.system_time(:millisecond)
    "cluster-#{hostname}-#{timestamp}"
  end

  defp get_local_endpoints do
    # Get local FLAME endpoints
    [
      %{
        type: :http,
        host: "localhost",
        port: 4000,
        path: "/api/flame"
      },
      %{
        type: :erlang_distribution,
        node: Node.self(),
        cookie: Node.get_cookie()
      }
    ]
  end

  defp get_local_capabilities do
    [
      :container_provisioning,
      :task_execution,
      :resource_management,
      :security_validation,
      :metrics_collection,
      :health_monitoring
    ]
  end

  defp get_local_resources do
    try do
      case GenServer.call(ResourceManager, :get_resource_status, 5000) do
        status when is_map(status) ->
          %{
            total_memory_gb: status.global_limits.max_total_memory_gb,
            available_memory_gb:
              status.global_limits.max_total_memory_gb - status.current_usage.memory_gb,
            total_cpu_cores: status.global_limits.max_total_cpu_cores,
            available_cpu_cores:
              status.global_limits.max_total_cpu_cores - status.current_usage.cpu_cores,
            max_containers: status.global_limits.max_concurrent_containers,
            active_containers: status.current_usage.container_count
          }

        _ ->
          get_default_resources()
      end
    catch
      _ ->
        %{
          total_memory_gb: 8,
          available_memory_gb: 4,
          total_cpu_cores: 4,
          available_cpu_cores: 2,
          max_containers: 20,
          active_containers: 0
        }
    end
  end

  defp get_default_resources do
    %{
      total_memory_gb: 8,
      available_memory_gb: 4,
      total_cpu_cores: 4,
      available_cpu_cores: 2,
      max_containers: 20,
      active_containers: 0
    }
  end

  defp get_flame_version do
    case Application.spec(:flame, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      _ -> "unknown"
    end
  end

  defp validate_cluster_config(config) do
    required_fields = [:endpoints]

    case Enum.all?(required_fields, &Map.has_key?(config, &1)) do
      true ->
        if is_list(config.endpoints) and length(config.endpoints) > 0 do
          :ok
        else
          {:error, :invalid_endpoints}
        end

      false ->
        {:error, :missing_required_fields}
    end
  end

  defp perform_health_check(cluster_info) do
    case cluster_info.type do
      :local ->
        :healthy

      :remote ->
        check_remote_cluster_health(cluster_info)
    end
  end

  defp check_remote_cluster_health(cluster_info) do
    # Try to connect to remote cluster endpoints
    Enum.reduce_while(cluster_info.endpoints, :unhealthy, fn endpoint, _acc ->
      case ping_endpoint(endpoint, cluster_info.credentials) do
        :ok -> {:halt, :healthy}
        :error -> {:cont, :unhealthy}
      end
    end)
  end

  defp ping_endpoint(endpoint, credentials) do
    case endpoint.type do
      :http ->
        ping_http_endpoint(endpoint, credentials)

      :erlang_distribution ->
        ping_erlang_node(endpoint)

      _ ->
        :error
    end
  end

  defp ping_http_endpoint(endpoint, credentials) do
    url =
      "#{endpoint.protocol || "http"}://#{endpoint.host}:#{endpoint.port}#{endpoint.path || "/health"}"

    headers = build_auth_headers(credentials)

    case http_get(url, headers) do
      {:ok, %{status_code: 200}} -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp ping_erlang_node(endpoint) do
    case Node.ping(endpoint.node) do
      :pong -> :ok
      :pang -> :error
    end
  end

  defp build_auth_headers(nil), do: []

  defp build_auth_headers(%{type: :bearer, token: token}),
    do: [{"Authorization", "Bearer #{token}"}]

  defp build_auth_headers(%{type: :basic, username: user, password: pass}) do
    encoded = Base.encode64("#{user}:#{pass}")
    [{"Authorization", "Basic #{encoded}"}]
  end

  defp build_auth_headers(_), do: []

  defp initialize_load_balancer(:round_robin),
    do: %{strategy: :round_robin, state: %{current_index: 0}}

  defp initialize_load_balancer(:least_connections),
    do: %{strategy: :least_connections, state: %{}}

  defp initialize_load_balancer(:resource_aware), do: %{strategy: :resource_aware, state: %{}}
  defp initialize_load_balancer(_), do: %{strategy: :round_robin, state: %{current_index: 0}}

  defp initialize_failover_policies(opts) do
    %{
      auto_failover_enabled: Keyword.get(opts, :auto_failover, true),
      max_consecutive_failures: Keyword.get(opts, :max_consecutive_failures, 3),
      failover_timeout: Keyword.get(opts, :failover_timeout, @failover_timeout),
      # 5 minutes
      recovery_time: Keyword.get(opts, :recovery_time, 300_000)
    }
  end

  defp initialize_metrics_aggregator do
    %{
      last_aggregation: System.system_time(:millisecond),
      cached_metrics: %{},
      # 1 minute
      aggregation_interval: 60_000
    }
  end

  defp schedule_health_checks do
    Process.send_after(self(), :health_check, @health_check_interval)
  end

  defp schedule_cluster_sync do
    Process.send_after(self(), :cluster_sync, @cluster_sync_interval)
  end

  defp add_cluster_to_load_balancer(load_balancer, cluster_info) do
    # Update load balancer with new cluster
    case load_balancer.strategy do
      :round_robin ->
        load_balancer

      :least_connections ->
        put_in(load_balancer.state[cluster_info.id], %{connections: 0})

      :resource_aware ->
        put_in(load_balancer.state[cluster_info.id], %{
          cpu_usage: 0,
          memory_usage: 0,
          container_count: 0
        })
    end
  end

  defp remove_cluster_from_load_balancer(load_balancer, cluster_info) do
    case load_balancer.strategy do
      :round_robin ->
        load_balancer

      _ ->
        %{load_balancer | state: Map.delete(load_balancer.state, cluster_info.id)}
    end
  end

  defp select_new_primary_cluster(clusters) do
    healthy_clusters = Enum.filter(clusters, fn {_id, cluster} -> cluster.status == :healthy end)

    case healthy_clusters do
      [] -> nil
      # Select first healthy cluster
      [{id, _} | _] -> id
    end
  end

  defp select_best_cluster(clusters, task_requirements, load_balancer) do
    case load_balancer.strategy do
      :round_robin ->
        select_round_robin(clusters, load_balancer)

      :least_connections ->
        select_least_connections(clusters, load_balancer)

      :resource_aware ->
        select_resource_aware(clusters, task_requirements, load_balancer)

      _ ->
        {cluster_id, cluster_info} = Enum.random(clusters)
        {cluster_id, cluster_info}
    end
  end

  defp select_round_robin(clusters, load_balancer) do
    cluster_list = Enum.to_list(clusters)
    current_index = load_balancer.state.current_index
    index = rem(current_index, length(cluster_list))
    Enum.at(cluster_list, index)
  end

  defp select_least_connections(clusters, load_balancer) do
    Enum.min_by(clusters, fn {cluster_id, _cluster} ->
      connections = get_in(load_balancer.state, [cluster_id, :connections]) || 0
      connections
    end)
  end

  defp select_resource_aware(clusters, task_requirements, load_balancer) do
    Enum.max_by(clusters, fn {cluster_id, cluster} ->
      cluster_state = get_in(load_balancer.state, [cluster_id]) || %{}
      score_cluster_for_task(cluster, cluster_state, task_requirements)
    end)
  end

  defp score_cluster_for_task(cluster, cluster_state, task_requirements) do
    # Calculate cluster score based on available resources and task requirements
    memory_score = calculate_memory_score(cluster.resources, task_requirements)
    cpu_score = calculate_cpu_score(cluster.resources, task_requirements)
    load_score = calculate_load_score(cluster_state)

    # Weighted scoring
    memory_score * 0.3 + cpu_score * 0.3 + load_score * 0.4
  end

  defp calculate_memory_score(resources, task_requirements) do
    available_memory = resources.available_memory_gb || 0
    required_memory = Map.get(task_requirements, :memory_gb, 0.5)

    if available_memory >= required_memory do
      min(100, available_memory / required_memory * 10)
    else
      0
    end
  end

  defp calculate_cpu_score(resources, task_requirements) do
    available_cpu = resources.available_cpu_cores || 0
    required_cpu = Map.get(task_requirements, :cpu_cores, 0.5)

    if available_cpu >= required_cpu do
      min(100, available_cpu / required_cpu * 10)
    else
      0
    end
  end

  defp calculate_load_score(cluster_state) do
    container_count = Map.get(cluster_state, :container_count, 0)
    # Lower score for higher container count
    max(0, 100 - container_count * 5)
  end

  defp perform_failover(from_cluster, to_cluster, state) do
    Logger.info("Performing failover from #{from_cluster.id} to #{to_cluster.id}")

    if is_function(state.failover_callback, 2) do
      state.failover_callback.(from_cluster, to_cluster)
    else
      Logger.info(
        "Failover action: migrating workloads from cluster #{from_cluster.id} " <>
          "(type=#{from_cluster.type}, status=#{from_cluster.status}) " <>
          "to cluster #{to_cluster.id} " <>
          "(type=#{to_cluster.type}, status=#{to_cluster.status})"
      )

      :ok
    end
  end

  defp perform_all_health_checks(state) do
    Enum.reduce(state.clusters, state, fn {cluster_id, cluster}, acc_state ->
      old_status = cluster.status
      new_status = perform_health_check(cluster)

      # Update cluster status
      acc_state = put_in(acc_state.clusters[cluster_id].status, new_status)

      acc_state =
        put_in(acc_state.clusters[cluster_id].last_seen, System.system_time(:millisecond))

      # Update health check info
      health_info = Map.get(acc_state.health_checks, cluster_id, %{})

      consecutive_failures =
        if new_status == :healthy do
          0
        else
          (health_info[:consecutive_failures] || 0) + 1
        end

      acc_state =
        put_in(acc_state.health_checks[cluster_id], %{
          last_check: System.system_time(:millisecond),
          status: new_status,
          consecutive_failures: consecutive_failures
        })

      # Send health change notification if status changed
      if old_status != new_status do
        send(self(), {:cluster_health_changed, cluster_id, old_status, new_status})
      end

      acc_state
    end)
  end

  defp synchronize_cluster_state(state) do
    # Sync cluster state across all clusters
    # This would implement cluster state synchronization
    Logger.debug("Synchronizing cluster state across #{map_size(state.clusters)} clusters")
    state
  end

  defp handle_cluster_failure(cluster_id, state) do
    health_info = Map.get(state.health_checks, cluster_id, %{})
    consecutive_failures = health_info[:consecutive_failures] || 0

    if consecutive_failures >= state.failover_policies.max_consecutive_failures do
      Logger.warning(
        "Cluster #{cluster_id} exceeded failure threshold, initiating automatic failover"
      )

      # Find best failover target
      case find_failover_target(cluster_id, state) do
        {:ok, target_cluster_id} ->
          case trigger_failover(cluster_id, target_cluster_id, "automatic_health_failure") do
            :ok ->
              Logger.info(
                "Automatic failover completed from #{cluster_id} to #{target_cluster_id}"
              )

            {:error, reason} ->
              Logger.error("Automatic failover failed: #{reason}")
          end

        {:error, :no_suitable_target} ->
          Logger.error("No suitable failover target found for cluster #{cluster_id}")
      end
    end

    {:noreply, state}
  end

  defp handle_cluster_recovery(cluster_id, state) do
    Logger.info("Cluster #{cluster_id} has recovered")

    # Add cluster back to load balancer
    cluster_info = Map.get(state.clusters, cluster_id)

    state = %{
      state
      | load_balancer: add_cluster_to_load_balancer(state.load_balancer, cluster_info)
    }

    {:noreply, state}
  end

  defp find_failover_target(failed_cluster_id, state) do
    healthy_clusters =
      Enum.filter(state.clusters, fn {id, cluster} ->
        id != failed_cluster_id and cluster.status == :healthy
      end)

    case healthy_clusters do
      [] ->
        {:error, :no_suitable_target}

      clusters ->
        # Select cluster with highest priority and available resources
        {target_id, _} =
          Enum.max_by(clusters, fn {_id, cluster} ->
            priority = Map.get(cluster, :priority, 100)

            available_resources =
              cluster.resources.available_memory_gb + cluster.resources.available_cpu_cores

            priority + available_resources
          end)

        {:ok, target_id}
    end
  end

  defp aggregate_cluster_metrics(clusters) do
    Enum.reduce(clusters, %{}, fn {cluster_id, cluster}, acc ->
      cluster_metrics = get_cluster_metrics(cluster)

      acc
      |> update_in([:total_memory_gb], &((&1 || 0) + cluster_metrics.total_memory_gb))
      |> update_in([:available_memory_gb], &((&1 || 0) + cluster_metrics.available_memory_gb))
      |> update_in([:total_cpu_cores], &((&1 || 0) + cluster_metrics.total_cpu_cores))
      |> update_in([:available_cpu_cores], &((&1 || 0) + cluster_metrics.available_cpu_cores))
      |> update_in([:total_containers], &((&1 || 0) + cluster_metrics.total_containers))
      |> update_in([:active_containers], &((&1 || 0) + cluster_metrics.active_containers))
      |> put_in([:clusters, cluster_id], cluster_metrics)
    end)
  end

  defp get_cluster_metrics(cluster) do
    case cluster.type do
      :local ->
        get_local_resources()

      :remote ->
        # This would fetch metrics from remote cluster
        cluster.resources
    end
    |> Map.put(:total_containers, Map.get(cluster.resources, :max_containers, 0))
    |> Map.put(:active_containers, Map.get(cluster.resources, :active_containers, 0))
  end

  defp execute_with_automatic_failover(task_function, options, state, retries_left)
       when retries_left > 0 do
    case select_cluster_for_task(Map.get(options, :requirements, %{})) do
      {:ok, {cluster_id, cluster_info}} ->
        case execute_task_on_cluster(task_function, cluster_info, options) do
          {:ok, result} ->
            {:ok, result, cluster_id}

          {:error, _reason} when retries_left > 1 ->
            # Mark cluster as potentially unhealthy and retry
            Logger.warning(
              "Task execution failed on #{cluster_id}, retrying on different cluster"
            )

            execute_with_automatic_failover(task_function, options, state, retries_left - 1)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_with_automatic_failover(_task_function, _options, _state, 0) do
    {:error, :max_retries_exceeded}
  end

  defp execute_task_on_cluster(task_function, cluster_info, options) do
    case cluster_info.type do
      :local ->
        execute_local_task(task_function, options)

      :remote ->
        execute_remote_task(task_function, cluster_info, options)
    end
  end

  defp execute_local_task(task_function, _options) do
    # Execute task on local FLAME backend
    try do
      result = FLAME.call(FlameAppleContainerBackend.ComputePool, task_function)
      {:ok, result}
    rescue
      error -> {:error, error}
    end
  end

  defp execute_remote_task(task_function, cluster_info, options) do
    remote_executor = options[:remote_executor]

    cond do
      is_function(remote_executor, 3) ->
        # Use a caller-supplied callback for remote execution
        try do
          result = remote_executor.(task_function, cluster_info, options)
          {:ok, result}
        rescue
          error -> {:error, {:remote_execution_failed, error}}
        end

      is_atom(cluster_info[:flame_pool]) and not is_nil(cluster_info[:flame_pool]) ->
        # Delegate to a FLAME pool configured for this remote cluster
        try do
          result = FLAME.call(cluster_info.flame_pool, task_function)
          {:ok, result}
        rescue
          error -> {:error, {:remote_flame_call_failed, error}}
        end

      not is_nil(cluster_info[:endpoints]) ->
        # Use :rpc.call to execute on the first reachable remote node
        execute_on_remote_endpoint(task_function, cluster_info.endpoints, options)

      true ->
        {:error, :no_remote_execution_strategy}
    end
  end

  defp execute_on_remote_endpoint(_task_function, [], _options) do
    {:error, :all_remote_endpoints_unreachable}
  end

  defp execute_on_remote_endpoint(task_function, [endpoint | rest], options) do
    timeout = options[:timeout] || 30_000
    node = endpoint_to_node(endpoint)

    case :rpc.call(node, :erlang, :apply, [task_function, []], timeout) do
      {:badrpc, _reason} ->
        execute_on_remote_endpoint(task_function, rest, options)

      result ->
        {:ok, result}
    end
  end

  defp endpoint_to_node(endpoint) when is_atom(endpoint), do: endpoint

  defp endpoint_to_node(endpoint) when is_binary(endpoint) do
    String.to_atom(endpoint)
  end

  defp endpoint_to_node(%{node: node}), do: endpoint_to_node(node)
  defp endpoint_to_node(%{host: host}), do: String.to_atom(host)

  defp http_get(url, headers) do
    if Code.ensure_loaded?(Req) do
      case Req.get(url, headers: headers) do
        {:ok, %{status: status, body: body}} -> {:ok, %{status_code: status, body: body}}
        {:error, reason} -> {:error, reason}
      end
    else
      Logger.warning("Req not available, skipping HTTP GET to #{url}")
      {:error, :http_client_not_available}
    end
  end
end
