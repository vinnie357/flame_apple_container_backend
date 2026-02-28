defmodule FLAME.AppleContainersBackend do
  @moduledoc """
  A `FLAME.Backend` using macOS Apple Containers.

  This backend provisions Apple Containers to run FLAME workers,
  following the same protocol as `FLAME.FlyBackend`.

  ## Configuration

      config :flame, :backend, FLAME.AppleContainersBackend

      config :flame, FLAME.AppleContainersBackend,
        image: "flame-worker:latest",
        dns_domain: "flame.local"

  ## Options

    * `:image` - The container image to run. Defaults to `"flame-worker:latest"`.

    * `:dns_domain` - DNS domain for container name resolution.
      Defaults to `"flame.local"`.

    * `:container_prefix` - Prefix for container names.
      Defaults to `"flame-worker"`.

    * `:erlang_cookie` - Cookie for distributed Erlang.
      Defaults to `Node.get_cookie()`.

    * `:boot_timeout` - Timeout for container boot in ms. Defaults to `30_000`.

    * `:env` - Extra environment variables as a list of `{key, value}` tuples
      or `"KEY=VALUE"` strings.

    * `:volumes` - Volume mounts as a list of `"host:container[:opts]"` strings.

    * `:network_name` - Network name for container clustering.

    * `:subnet` - Subnet for the container network.

    * `:enable_clustering` - Whether to enable container networking. Defaults to `false`.

    * `:log` - Log level for backend messages, or `false` to disable. Defaults to `false`.
  """

  @behaviour FLAME.Backend

  require Logger

  alias FLAME.AppleContainers.CLI

  @derive {Inspect,
           only: [
             :image,
             :dns_domain,
             :container_prefix,
             :runner_node_base,
             :runner_node_name,
             :remote_terminator_pid,
             :boot_timeout,
             :network_name,
             :enable_clustering
           ]}
  defstruct [
    :parent_ref,
    :encoded_parent,
    :runner_node_base,
    :runner_node_name,
    :remote_terminator_pid,
    :image,
    :dns_domain,
    :container_prefix,
    :erlang_cookie,
    :boot_timeout,
    :env,
    :volumes,
    :network_name,
    :subnet,
    :enable_clustering,
    :log
  ]

  @valid_opts [
    :image,
    :dns_domain,
    :container_prefix,
    :erlang_cookie,
    :boot_timeout,
    :env,
    :volumes,
    :network_name,
    :subnet,
    :enable_clustering,
    :log,
    :terminator_sup
  ]

  @impl true
  def init(opts) do
    conf = Application.get_env(:flame, __MODULE__) || []

    default = %__MODULE__{
      image: "flame-worker:latest",
      dns_domain: "flame.local",
      container_prefix: "flame-worker",
      erlang_cookie: Node.get_cookie(),
      boot_timeout: 30_000,
      env: [],
      volumes: [],
      network_name: "flame-cluster-net",
      subnet: nil,
      enable_clustering: false,
      log: Keyword.get(conf, :log, false)
    }

    provided_opts =
      conf
      |> Keyword.merge(opts)
      |> Keyword.validate!(@valid_opts)

    state = Map.merge(default, Map.new(provided_opts))

    dns_domain = get_and_validate_dns_domain(state.dns_domain, provided_opts)
    state = %{state | dns_domain: dns_domain}

    state = %{state | runner_node_base: "#{state.container_prefix}-flame-#{rand_id(20)}"}
    parent_ref = make_ref()

    encoded_parent =
      parent_ref
      |> FLAME.Parent.new(self(), __MODULE__, state.runner_node_base, "FLAME_HOST")
      |> FLAME.Parent.encode()

    new_state = %{state | parent_ref: parent_ref, encoded_parent: encoded_parent}

    {:ok, new_state}
  end

  @impl true
  def remote_boot(%__MODULE__{parent_ref: parent_ref} = state) do
    container_name = "#{state.runner_node_base}"
    hostname = "#{container_name}.#{state.dns_domain}"

    env =
      [
        {"FLAME_PARENT", state.encoded_parent},
        {"FLAME_HOST", hostname},
        {"PHX_SERVER", "false"},
        {"RELEASE_DISTRIBUTION", "name"},
        {"RELEASE_NODE", "#{state.runner_node_base}@#{hostname}"},
        {"RELEASE_COOKIE", to_string(state.erlang_cookie)}
      ] ++ normalize_env(state.env)

    args = build_container_run_args(state, container_name, env)

    if state.log do
      Logger.log(state.log, "#{inspect(__MODULE__)} starting container #{container_name}")
    end

    case CLI.adapter().run_container(args) do
      {_output, 0} ->
        remote_terminator_pid =
          receive do
            {^parent_ref, {:remote_up, remote_terminator_pid}} ->
              remote_terminator_pid
          after
            state.boot_timeout ->
              Logger.error(
                "failed to connect to container #{container_name} within #{state.boot_timeout}ms"
              )

              cleanup_container(container_name)
              exit(:timeout)
          end

        new_state = %{
          state
          | remote_terminator_pid: remote_terminator_pid,
            runner_node_name: node(remote_terminator_pid)
        }

        {:ok, remote_terminator_pid, new_state}

      {error, code} ->
        Logger.error("failed to start container #{container_name} (exit #{code}): #{error}")
        {:error, {:container_start_failed, code, error}}
    end
  end

  @impl true
  def remote_spawn_monitor(%__MODULE__{} = state, func) when is_function(func, 0) do
    {:ok, do_spawn_monitor(state, func)}
  end

  def remote_spawn_monitor(%__MODULE__{} = state, {mod, fun, args})
      when is_atom(mod) and is_atom(fun) and is_list(args) do
    {:ok, do_spawn_monitor(state, {mod, fun, args})}
  end

  def remote_spawn_monitor(%__MODULE__{}, other) do
    raise ArgumentError,
          "expected a null arity function or {mod, func, args}. Got: #{inspect(other)}"
  end

  defp do_spawn_monitor(%{runner_node_name: node_name}, func) when is_function(func, 0) do
    if node_name == node(), do: spawn_monitor(func), else: Node.spawn_monitor(node_name, func)
  end

  defp do_spawn_monitor(%{runner_node_name: node_name}, {mod, fun, args}) do
    if node_name == node(),
      do: spawn_monitor(mod, fun, args),
      else: Node.spawn_monitor(node_name, mod, fun, args)
  end

  @impl true
  def system_shutdown do
    System.stop()
  end

  @impl true
  def handle_info(msg, state) do
    if state.log do
      Logger.log(state.log, "#{inspect(__MODULE__)} received: #{inspect(msg)}")
    end

    {:noreply, state}
  end

  # --- Private helpers ---

  defp build_container_run_args(state, container_name, env) do
    env_args = build_env_args(env)
    volume_args = build_volume_args(state.volumes)

    network_args =
      if state.enable_clustering && state.network_name do
        ["--network", state.network_name]
      else
        []
      end

    dns_args =
      if state.dns_domain do
        ["--dns-search", state.dns_domain]
      else
        []
      end

    ["--name", container_name, "--detach", "--rm"] ++
      env_args ++ dns_args ++ network_args ++ volume_args ++ [state.image]
  end

  defp build_env_args(env) when is_list(env) do
    Enum.flat_map(env, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        ["--env", "#{key}=#{value}"]

      env_string when is_binary(env_string) ->
        ["--env", env_string]

      _ ->
        []
    end)
  end

  defp build_env_args(_), do: []

  defp build_volume_args(nil), do: []
  defp build_volume_args([]), do: []

  defp build_volume_args(volumes) when is_list(volumes) do
    Enum.flat_map(volumes, fn volume_spec ->
      ["--volume", volume_spec]
    end)
  end

  defp normalize_env(env) when is_list(env), do: env
  defp normalize_env(%{} = env), do: Enum.to_list(env)
  defp normalize_env(_), do: []

  defp cleanup_container(container_name) do
    Logger.info("Cleaning up container #{container_name}")

    case CLI.adapter().stop_container(container_name, time: 10) do
      {_output, 0} ->
        :ok

      {_error, _code} ->
        case CLI.adapter().kill_container(container_name) do
          {_output, 0} -> :ok
          {_error, _code} -> :error
        end
    end
  end

  defp rand_id(len) do
    len
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
    |> binary_part(0, len)
  end

  # DNS domain validation

  defp get_and_validate_dns_domain(requested_domain, _opts) do
    validate_dns_domain_against_system(requested_domain)
  end

  defp validate_dns_domain_against_system(requested_domain) do
    case CLI.adapter().list_dns_domains() do
      {output, 0} ->
        available_domains =
          output
          |> String.trim()
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == "" or &1 == "DOMAIN"))

        select_dns_domain(requested_domain, available_domains)

      {_error, _} ->
        requested_domain
    end
  end

  defp select_dns_domain(requested_domain, available_domains) do
    if requested_domain in available_domains do
      requested_domain
    else
      select_fallback_domain(requested_domain, available_domains)
    end
  end

  defp select_fallback_domain(requested_domain, available_domains) do
    cond do
      "test.local" in available_domains ->
        "test.local"

      available_domains != [] ->
        hd(available_domains)

      true ->
        requested_domain
    end
  end
end
