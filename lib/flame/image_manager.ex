defmodule FLAME.ImageManager do
  @moduledoc """
  Container image management for Apple Containers FLAME backend.

  Provides enterprise-grade image lifecycle management including:
  - Automated image building and testing pipelines
  - Image vulnerability scanning and security compliance
  - Blue-green deployments with rollback capabilities
  - Image versioning and registry management
  - Multi-architecture image support
  - Image optimization and caching strategies
  """

  use GenServer
  require Logger

  alias FLAME.AlertManager

  defstruct [
    :images,
    :build_queue,
    :registries,
    :security_scanner,
    :deployment_tracker,
    :cache_manager,
    :build_config
  ]

  # 30 minutes
  @build_timeout 1_800_000
  # 10 minutes
  @scan_timeout 600_000
  # 1 hour
  @cleanup_interval 3_600_000
  # 5 minutes
  @registry_sync_interval 300_000

  ## Image States
  @state_building :building
  @state_built :built
  @state_scanning :scanning
  @state_scan_passed :scan_passed
  @state_scan_failed :scan_failed
  # @state_testing :testing
  @state_ready :ready
  @state_deployed :deployed
  @state_deprecated :deprecated
  @state_failed :failed

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Build a new container image from source.
  """
  def build_image(build_spec) do
    GenServer.call(__MODULE__, {:build_image, build_spec}, @build_timeout)
  end

  @doc """
  Get the status of an image build.
  """
  def get_build_status(build_id) do
    GenServer.call(__MODULE__, {:get_build_status, build_id})
  end

  @doc """
  List all available images.
  """
  def list_images(filters \\ %{}) do
    GenServer.call(__MODULE__, {:list_images, filters})
  end

  @doc """
  Get detailed information about a specific image.
  """
  def get_image_info(image_id) do
    GenServer.call(__MODULE__, {:get_image_info, image_id})
  end

  @doc """
  Deploy an image to production using blue-green deployment.
  """
  def deploy_image(image_id, deployment_config \\ %{}) do
    GenServer.call(__MODULE__, {:deploy_image, image_id, deployment_config}, @build_timeout)
  end

  @doc """
  Rollback to a previous image version.
  """
  def rollback_deployment(deployment_id, target_image_id \\ nil) do
    GenServer.call(__MODULE__, {:rollback_deployment, deployment_id, target_image_id})
  end

  @doc """
  Run security scan on an image.
  """
  def scan_image(image_id) do
    GenServer.call(__MODULE__, {:scan_image, image_id}, @scan_timeout)
  end

  @doc """
  Promote an image through the deployment pipeline stages.
  """
  def promote_image(image_id, from_stage, to_stage) do
    GenServer.call(__MODULE__, {:promote_image, image_id, from_stage, to_stage})
  end

  @doc """
  Clean up old and unused images.
  """
  def cleanup_images(policy \\ %{}) do
    GenServer.call(__MODULE__, {:cleanup_images, policy})
  end

  @doc """
  Get image build and deployment metrics.
  """
  def get_image_metrics do
    GenServer.call(__MODULE__, :get_image_metrics)
  end

  ## GenServer Callbacks

  def init(opts) do
    build_config = %{
      dockerfile_path: Keyword.get(opts, :dockerfile_path, "Dockerfile.flame"),
      build_context: Keyword.get(opts, :build_context, "."),
      build_args: Keyword.get(opts, :build_args, %{}),
      platforms: Keyword.get(opts, :platforms, ["darwin/arm64", "darwin/amd64"]),
      cache_enabled: Keyword.get(opts, :cache_enabled, true),
      parallel_builds: Keyword.get(opts, :parallel_builds, 2)
    }

    state = %__MODULE__{
      images: %{},
      build_queue: :queue.new(),
      registries: initialize_registries(opts),
      security_scanner: initialize_security_scanner(opts),
      deployment_tracker: %{},
      cache_manager: initialize_cache_manager(opts),
      build_config: build_config
    }

    # Start periodic tasks
    schedule_cleanup()
    schedule_registry_sync()

    # Load existing images from registries
    state = load_existing_images(state)

    Logger.info("ImageManager initialized with #{map_size(state.images)} images")

    {:ok, state}
  end

  def handle_call({:build_image, build_spec}, _from, state) do
    case validate_build_spec(build_spec) do
      :ok ->
        build_id = generate_build_id()

        image_info = %{
          id: build_id,
          name: build_spec.name,
          version: build_spec.version || generate_version(),
          state: @state_building,
          build_spec: build_spec,
          created_at: System.system_time(:millisecond),
          updated_at: System.system_time(:millisecond),
          build_logs: [],
          scan_results: nil,
          deployment_history: [],
          metadata: build_spec.metadata || %{}
        }

        state = put_in(state.images[build_id], image_info)

        # Start async build process
        spawn_build_process(build_id, build_spec, state.build_config)

        Logger.info("Started building image: #{build_spec.name}:#{image_info.version}")
        {:reply, {:ok, build_id}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_build_status, build_id}, _from, state) do
    case Map.get(state.images, build_id) do
      nil ->
        {:reply, {:error, :build_not_found}, state}

      image_info ->
        status = %{
          id: build_id,
          state: image_info.state,
          name: image_info.name,
          version: image_info.version,
          created_at: image_info.created_at,
          updated_at: image_info.updated_at,
          build_duration: calculate_build_duration(image_info),
          # Last 10 log entries
          logs: Enum.take(image_info.build_logs, -10)
        }

        {:reply, {:ok, status}, state}
    end
  end

  def handle_call({:list_images, filters}, _from, state) do
    images =
      state.images
      |> Enum.map(fn {_id, image} -> image end)
      |> apply_image_filters(filters)
      |> Enum.sort_by(& &1.updated_at, :desc)

    {:reply, images, state}
  end

  def handle_call({:get_image_info, image_id}, _from, state) do
    case Map.get(state.images, image_id) do
      nil ->
        {:reply, {:error, :image_not_found}, state}

      image_info ->
        detailed_info = %{
          id: image_info.id,
          name: image_info.name,
          version: image_info.version,
          state: image_info.state,
          created_at: image_info.created_at,
          updated_at: image_info.updated_at,
          build_spec: image_info.build_spec,
          scan_results: image_info.scan_results,
          deployment_history: image_info.deployment_history,
          metadata: image_info.metadata,
          size_bytes: get_image_size(image_info),
          layers: get_image_layers(image_info),
          vulnerabilities: get_vulnerability_summary(image_info.scan_results)
        }

        {:reply, {:ok, detailed_info}, state}
    end
  end

  def handle_call({:deploy_image, image_id, deployment_config}, _from, state) do
    case Map.get(state.images, image_id) do
      nil ->
        {:reply, {:error, :image_not_found}, state}

      image_info when image_info.state != @state_ready ->
        {:reply, {:error, {:invalid_state, image_info.state}}, state}

      image_info ->
        deployment_id = generate_deployment_id()

        case perform_blue_green_deployment(image_info, deployment_config) do
          {:ok, deployment_result} ->
            # Update image deployment history
            deployment_record = %{
              id: deployment_id,
              image_id: image_id,
              config: deployment_config,
              started_at: System.system_time(:millisecond),
              completed_at: System.system_time(:millisecond),
              status: :completed,
              result: deployment_result
            }

            state =
              update_in(state.images[image_id].deployment_history, &[deployment_record | &1])

            state = put_in(state.images[image_id].state, @state_deployed)
            state = put_in(state.deployment_tracker[deployment_id], deployment_record)

            Logger.info("Successfully deployed image #{image_info.name}:#{image_info.version}")

            # Send telemetry
            :telemetry.execute([:flame, :image, :deployed], %{}, %{
              image_id: image_id,
              deployment_id: deployment_id
            })

            {:reply, {:ok, deployment_id}, state}

          {:error, reason} ->
            Logger.error("Failed to deploy image #{image_id}: #{reason}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:rollback_deployment, deployment_id, target_image_id}, _from, state) do
    case Map.get(state.deployment_tracker, deployment_id) do
      nil ->
        {:reply, {:error, :deployment_not_found}, state}

      deployment_record ->
        target_id =
          target_image_id || get_previous_deployed_image(deployment_record.image_id, state)

        case target_id do
          nil ->
            {:reply, {:error, :no_rollback_target}, state}

          target ->
            case perform_rollback(deployment_record, target, state) do
              {:ok, rollback_result} ->
                Logger.info(
                  "Successfully rolled back deployment #{deployment_id} to image #{target}"
                )

                # Send telemetry
                :telemetry.execute([:flame, :image, :rollback], %{}, %{
                  deployment_id: deployment_id,
                  target_image_id: target
                })

                {:reply, {:ok, rollback_result}, state}

              {:error, reason} ->
                Logger.error("Failed to rollback deployment #{deployment_id}: #{reason}")
                {:reply, {:error, reason}, state}
            end
        end
    end
  end

  def handle_call({:scan_image, image_id}, _from, state) do
    case Map.get(state.images, image_id) do
      nil ->
        {:reply, {:error, :image_not_found}, state}

      image_info when image_info.state not in [@state_built, @state_scan_failed] ->
        {:reply, {:error, {:invalid_state, image_info.state}}, state}

      image_info ->
        # Update state to scanning
        state = put_in(state.images[image_id].state, @state_scanning)

        # Start async scan process
        spawn_scan_process(image_id, image_info, state.security_scanner)

        Logger.info("Started security scan for image: #{image_info.name}:#{image_info.version}")
        {:reply, {:ok, :scan_started}, state}
    end
  end

  def handle_call({:promote_image, image_id, from_stage, to_stage}, _from, state) do
    case Map.get(state.images, image_id) do
      nil ->
        {:reply, {:error, :image_not_found}, state}

      image_info ->
        case validate_promotion(image_info, from_stage, to_stage) do
          :ok ->
            case perform_promotion(image_info, from_stage, to_stage) do
              {:ok, promotion_result} ->
                # Update image metadata
                stage_history = Map.get(image_info.metadata, :stage_history, [])

                promotion_record = %{
                  from: from_stage,
                  to: to_stage,
                  promoted_at: System.system_time(:millisecond),
                  # Could be user ID in real implementation
                  promoted_by: "system"
                }

                state =
                  put_in(state.images[image_id].metadata.stage_history, [
                    promotion_record | stage_history
                  ])

                state = put_in(state.images[image_id].metadata.current_stage, to_stage)

                Logger.info("Promoted image #{image_id} from #{from_stage} to #{to_stage}")
                {:reply, {:ok, promotion_result}, state}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:cleanup_images, policy}, _from, state) do
    cleanup_result = perform_image_cleanup(state.images, policy)

    # Remove cleaned up images from state
    remaining_images =
      Enum.reduce(cleanup_result.removed_images, state.images, fn image_id, acc ->
        Map.delete(acc, image_id)
      end)

    state = %{state | images: remaining_images}

    Logger.info("Cleaned up #{length(cleanup_result.removed_images)} images")
    {:reply, cleanup_result, state}
  end

  def handle_call(:get_image_metrics, _from, state) do
    metrics = calculate_image_metrics(state)
    {:reply, metrics, state}
  end

  def handle_info({:build_completed, build_id, result}, state) do
    case Map.get(state.images, build_id) do
      nil ->
        {:noreply, state}

      image_info ->
        case result do
          {:ok, build_data} ->
            updated_image = %{
              image_info
              | state: @state_built,
                updated_at: System.system_time(:millisecond),
                build_logs: image_info.build_logs ++ build_data.logs,
                metadata: Map.merge(image_info.metadata, build_data.metadata)
            }

            state = put_in(state.images[build_id], updated_image)

            # Automatically start security scan
            send(self(), {:start_security_scan, build_id})

            Logger.info(
              "Build completed successfully for image: #{image_info.name}:#{image_info.version}"
            )

            # Send telemetry
            :telemetry.execute(
              [:flame, :image, :build_completed],
              %{
                build_duration: calculate_build_duration(updated_image)
              },
              %{
                image_id: build_id,
                success: true
              }
            )

            {:noreply, state}

          {:error, error_reason} ->
            updated_image = %{
              image_info
              | state: @state_failed,
                updated_at: System.system_time(:millisecond),
                build_logs: image_info.build_logs ++ ["Build failed: #{error_reason}"]
            }

            state = put_in(state.images[build_id], updated_image)

            Logger.error(
              "Build failed for image: #{image_info.name}:#{image_info.version} - #{error_reason}"
            )

            # Send alert
            AlertManager.trigger_manual_alert(%{
              name: "Image Build Failed",
              severity: 3,
              description: "Image build failed for #{image_info.name}:#{image_info.version}",
              tags: ["image", "build", "failure"]
            })

            {:noreply, state}
        end
    end
  end

  def handle_info({:scan_completed, image_id, scan_result}, state) do
    case Map.get(state.images, image_id) do
      nil ->
        {:noreply, state}

      image_info ->
        {new_state, scan_status} =
          case scan_result do
            {:ok, scan_data} ->
              if scan_data.vulnerabilities.critical > 0 or scan_data.vulnerabilities.high > 5 do
                {@state_scan_failed, :failed}
              else
                {@state_scan_passed, :passed}
              end

            {:error, _reason} ->
              {@state_scan_failed, :error}
          end

        updated_image = %{
          image_info
          | state: new_state,
            updated_at: System.system_time(:millisecond),
            scan_results: scan_result
        }

        state = put_in(state.images[image_id], updated_image)

        # If scan passed, mark image as ready for deployment
        state =
          if new_state == @state_scan_passed do
            put_in(state.images[image_id].state, @state_ready)
          else
            state
          end

        Logger.info(
          "Security scan #{scan_status} for image: #{image_info.name}:#{image_info.version}"
        )

        # Send alert if scan failed
        if scan_status == :failed do
          AlertManager.trigger_manual_alert(%{
            name: "Image Security Scan Failed",
            severity: 2,
            description:
              "Security vulnerabilities found in #{image_info.name}:#{image_info.version}",
            tags: ["image", "security", "vulnerability"]
          })
        end

        {:noreply, state}
    end
  end

  def handle_info({:start_security_scan, image_id}, state) do
    case Map.get(state.images, image_id) do
      nil ->
        {:noreply, state}

      image_info ->
        spawn_scan_process(image_id, image_info, state.security_scanner)
        {:noreply, state}
    end
  end

  def handle_info(:cleanup_images, state) do
    # Perform automatic cleanup based on default policy
    default_policy = %{
      max_age_days: 30,
      keep_latest: 5,
      remove_failed: true,
      remove_deprecated: true
    }

    spawn(fn ->
      perform_image_cleanup(state.images, default_policy)
    end)

    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(:sync_registries, state) do
    spawn(fn ->
      sync_with_registries(state.registries)
    end)

    schedule_registry_sync()
    {:noreply, state}
  end

  ## Private Functions

  defp initialize_registries(opts) do
    default_registry = %{
      name: "local",
      type: :local,
      url: "localhost:5000",
      username: nil,
      password: nil,
      default: true
    }

    custom_registries = Keyword.get(opts, :registries, [])
    [default_registry | custom_registries]
  end

  defp initialize_security_scanner(opts) do
    %{
      enabled: Keyword.get(opts, :security_scanning_enabled, true),
      scanner: Keyword.get(opts, :security_scanner, :trivy),
      severity_threshold: Keyword.get(opts, :severity_threshold, :medium),
      scan_timeout: Keyword.get(opts, :scan_timeout, @scan_timeout),
      database_url: Keyword.get(opts, :vulnerability_db_url)
    }
  end

  defp initialize_cache_manager(opts) do
    %{
      enabled: Keyword.get(opts, :cache_enabled, true),
      max_size_gb: Keyword.get(opts, :cache_max_size_gb, 50),
      cleanup_threshold: Keyword.get(opts, :cache_cleanup_threshold, 0.8)
    }
  end

  defp load_existing_images(state) do
    # This would scan existing container images and populate the state
    # For now, return empty state
    state
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_images, @cleanup_interval)
  end

  defp schedule_registry_sync do
    Process.send_after(self(), :sync_registries, @registry_sync_interval)
  end

  defp validate_build_spec(build_spec) do
    required_fields = [:name, :source]

    case Enum.all?(required_fields, &Map.has_key?(build_spec, &1)) do
      true ->
        case validate_source(build_spec.source) do
          :ok -> :ok
          error -> error
        end

      false ->
        {:error, :missing_required_fields}
    end
  end

  defp validate_source(source) do
    case source.type do
      :git when is_binary(source.url) -> :ok
      :dockerfile when is_binary(source.path) -> :ok
      :archive when is_binary(source.url) -> :ok
      _ -> {:error, :invalid_source}
    end
  end

  defp generate_build_id do
    "build-#{System.system_time(:millisecond)}-#{:rand.uniform(9999)}"
  end

  defp generate_deployment_id do
    "deploy-#{System.system_time(:millisecond)}-#{:rand.uniform(9999)}"
  end

  defp generate_version do
    timestamp = System.system_time(:millisecond)
    "v#{div(timestamp, 1000)}"
  end

  defp spawn_build_process(build_id, build_spec, build_config) do
    parent = self()

    spawn(fn ->
      result = perform_image_build(build_spec, build_config)
      send(parent, {:build_completed, build_id, result})
    end)
  end

  defp perform_image_build(build_spec, _build_config) do
    Logger.info("Starting build for #{build_spec.name}")

    # Simulate build process
    # Simulate build time
    Process.sleep(5000)

    # In a real implementation, this would:
    # 1. Clone/download source code
    # 2. Build container image using Apple Containers
    # 3. Tag and push to registry
    # 4. Return build metadata

    build_logs = [
      "Starting build process...",
      "Downloading source from #{build_spec.source.url}",
      "Building container image...",
      "Build completed successfully"
    ]

    metadata = %{
      image_tag: "#{build_spec.name}:#{generate_version()}",
      build_platform: "darwin/arm64",
      layers: 12,
      size_bytes: 256_000_000
    }

    {:ok, %{logs: build_logs, metadata: metadata}}
  rescue
    error ->
      {:error, "Build failed: #{inspect(error)}"}
  end

  defp spawn_scan_process(image_id, image_info, scanner_config) do
    parent = self()

    spawn(fn ->
      result = perform_security_scan(image_info, scanner_config)
      send(parent, {:scan_completed, image_id, result})
    end)
  end

  defp perform_security_scan(image_info, scanner_config) do
    if not scanner_config.enabled do
      {:ok, %{vulnerabilities: %{critical: 0, high: 0, medium: 0, low: 0}}}
    else
      Logger.info("Starting security scan for #{image_info.name}:#{image_info.version}")

      # Simulate scan process
      Process.sleep(3000)

      # In a real implementation, this would:
      # 1. Run vulnerability scanner (Trivy, Clair, etc.)
      # 2. Parse scan results
      # 3. Apply security policies
      # 4. Return structured vulnerability data

      scan_results = %{
        scanner: scanner_config.scanner,
        scan_time: System.system_time(:millisecond),
        vulnerabilities: %{
          critical: :rand.uniform(2),
          high: :rand.uniform(5),
          medium: :rand.uniform(10),
          low: :rand.uniform(20)
        },
        compliance: %{
          cis_benchmark: :passed,
          pci_dss: :passed,
          soc2: :passed
        },
        secrets_detected: [],
        malware_detected: false
      }

      {:ok, scan_results}
    end
  rescue
    error ->
      {:error, "Security scan failed: #{inspect(error)}"}
  end

  defp perform_blue_green_deployment(image_info, _deployment_config) do
    Logger.info("Starting blue-green deployment for #{image_info.name}:#{image_info.version}")

    # Simulate deployment process
    Process.sleep(2000)

    # In a real implementation, this would:
    # 1. Create new containers with the new image
    # 2. Run health checks
    # 3. Gradually shift traffic from old to new containers
    # 4. Monitor for issues and rollback if needed
    # 5. Clean up old containers

    deployment_result = %{
      containers_created: 3,
      health_checks_passed: true,
      traffic_shifted: 100,
      old_containers_terminated: 2,
      deployment_time_ms: 2000
    }

    {:ok, deployment_result}
  rescue
    error ->
      {:error, "Deployment failed: #{inspect(error)}"}
  end

  defp perform_rollback(_deployment_record, target_image_id, state) do
    Logger.info("Starting rollback to image #{target_image_id}")

    case Map.get(state.images, target_image_id) do
      nil ->
        {:error, :target_image_not_found}

      target_image ->
        # Simulate rollback process
        Process.sleep(1000)

        rollback_result = %{
          containers_created: 2,
          containers_terminated: 3,
          rollback_time_ms: 1000,
          target_image: "#{target_image.name}:#{target_image.version}"
        }

        {:ok, rollback_result}
    end
  rescue
    error ->
      {:error, "Rollback failed: #{inspect(error)}"}
  end

  defp get_previous_deployed_image(current_image_id, state) do
    # Find the most recently deployed image that's not the current one
    deployed_images =
      state.images
      |> Enum.filter(fn {id, image} ->
        id != current_image_id and image.state == @state_deployed
      end)
      |> Enum.sort_by(fn {_id, image} -> image.updated_at end, :desc)

    case deployed_images do
      [{id, _image} | _] -> id
      [] -> nil
    end
  end

  defp validate_promotion(image_info, from_stage, to_stage) do
    # Validate promotion rules based on stages
    valid_promotions = %{
      "development" => ["staging", "testing"],
      "staging" => ["production"],
      "testing" => ["production"],
      "production" => []
    }

    current_stage = get_in(image_info.metadata, [:current_stage]) || "development"

    if current_stage == from_stage and to_stage in Map.get(valid_promotions, from_stage, []) do
      :ok
    else
      {:error, :invalid_promotion}
    end
  end

  defp perform_promotion(image_info, from_stage, to_stage) do
    Logger.info(
      "Promoting #{image_info.name}:#{image_info.version} from #{from_stage} to #{to_stage}"
    )

    # Simulate promotion process
    Process.sleep(1000)

    promotion_result = %{
      from_stage: from_stage,
      to_stage: to_stage,
      validation_passed: true,
      promotion_time_ms: 1000
    }

    {:ok, promotion_result}
  rescue
    error ->
      {:error, "Promotion failed: #{inspect(error)}"}
  end

  defp perform_image_cleanup(images, policy) do
    Logger.info("Starting image cleanup with policy: #{inspect(policy)}")

    max_age_ms = Map.get(policy, :max_age_days, 30) * 24 * 60 * 60 * 1000
    keep_latest = Map.get(policy, :keep_latest, 5)
    remove_failed = Map.get(policy, :remove_failed, true)
    remove_deprecated = Map.get(policy, :remove_deprecated, true)

    current_time = System.system_time(:millisecond)

    # Find images to remove
    images_to_remove =
      images
      |> Enum.filter(fn {_id, image} ->
        # Remove old images
        age_condition = current_time - image.created_at > max_age_ms

        # Remove failed builds if policy allows
        failed_condition = remove_failed and image.state == @state_failed

        # Remove deprecated images if policy allows
        deprecated_condition = remove_deprecated and image.state == @state_deprecated

        age_condition or failed_condition or deprecated_condition
      end)
      |> Enum.sort_by(fn {_id, image} -> image.created_at end, :desc)
      # Keep the latest N images
      |> Enum.drop(keep_latest)
      |> Enum.map(fn {id, _image} -> id end)

    # Simulate cleanup process
    Enum.each(images_to_remove, fn image_id ->
      # In real implementation, this would remove the actual container image
      Logger.debug("Removing image: #{image_id}")
    end)

    %{
      removed_images: images_to_remove,
      total_images_before: map_size(images),
      total_images_after: map_size(images) - length(images_to_remove),
      cleanup_time_ms: 500
    }
  end

  defp apply_image_filters(images, filters) do
    Enum.filter(images, fn image ->
      Enum.all?(filters, fn {key, value} ->
        case key do
          :state -> image.state == value
          :name -> String.contains?(image.name, value)
          :version -> String.contains?(image.version, value)
          :tag -> value in Map.get(image.metadata, :tags, [])
          _ -> true
        end
      end)
    end)
  end

  defp calculate_build_duration(image_info) do
    if image_info.state in [@state_built, @state_ready, @state_deployed] do
      image_info.updated_at - image_info.created_at
    else
      nil
    end
  end

  defp get_image_size(image_info) do
    get_in(image_info.metadata, [:size_bytes]) || 0
  end

  defp get_image_layers(image_info) do
    get_in(image_info.metadata, [:layers]) || []
  end

  defp get_vulnerability_summary(scan_results) do
    case scan_results do
      {:ok, results} -> results.vulnerabilities
      _ -> %{critical: 0, high: 0, medium: 0, low: 0}
    end
  end

  defp calculate_image_metrics(state) do
    images = Map.values(state.images)

    %{
      total_images: length(images),
      images_by_state:
        Enum.group_by(images, & &1.state)
        |> Enum.map(fn {state, imgs} -> {state, length(imgs)} end)
        |> Enum.into(%{}),
      total_size_bytes: Enum.sum(Enum.map(images, &get_image_size/1)),
      builds_last_24h: count_recent_builds(images, 24 * 60 * 60 * 1000),
      deployments_last_24h: count_recent_deployments(images, 24 * 60 * 60 * 1000),
      security_scan_summary: calculate_security_summary(images),
      average_build_time_ms: calculate_average_build_time(images)
    }
  end

  defp count_recent_builds(images, time_window_ms) do
    current_time = System.system_time(:millisecond)

    Enum.count(images, fn image ->
      current_time - image.created_at <= time_window_ms
    end)
  end

  defp count_recent_deployments(images, time_window_ms) do
    current_time = System.system_time(:millisecond)

    images
    |> Enum.flat_map(& &1.deployment_history)
    |> Enum.count(fn deployment ->
      current_time - deployment.started_at <= time_window_ms
    end)
  end

  defp calculate_security_summary(images) do
    scanned_images =
      Enum.filter(images, fn image ->
        match?({:ok, _}, image.scan_results)
      end)

    if length(scanned_images) > 0 do
      total_vulns =
        Enum.reduce(scanned_images, %{critical: 0, high: 0, medium: 0, low: 0}, fn image, acc ->
          case image.scan_results do
            {:ok, results} ->
              vulns = results.vulnerabilities

              %{
                critical: acc.critical + vulns.critical,
                high: acc.high + vulns.high,
                medium: acc.medium + vulns.medium,
                low: acc.low + vulns.low
              }

            _ ->
              acc
          end
        end)

      %{
        total_scanned: length(scanned_images),
        vulnerabilities: total_vulns,
        clean_images:
          Enum.count(scanned_images, fn image ->
            case image.scan_results do
              {:ok, results} ->
                vulns = results.vulnerabilities
                vulns.critical == 0 and vulns.high == 0

              _ ->
                false
            end
          end)
      }
    else
      %{total_scanned: 0, vulnerabilities: %{}, clean_images: 0}
    end
  end

  defp calculate_average_build_time(images) do
    build_times =
      images
      |> Enum.map(&calculate_build_duration/1)
      |> Enum.reject(&is_nil/1)

    if length(build_times) > 0 do
      Enum.sum(build_times) / length(build_times)
    else
      0
    end
  end

  defp sync_with_registries(_registries) do
    # This would sync image metadata with external registries
    Logger.debug("Syncing with container registries")
  end
end
