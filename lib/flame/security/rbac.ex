defmodule FLAME.Security.RBAC do
  @moduledoc """
  Role-Based Access Control system for FLAME operations.

  Provides comprehensive permission management with role hierarchies,
  resource-based permissions, and dynamic policy evaluation.
  """

  use GenServer
  require Logger

  alias FLAME.Security.AuditLogger

  # Role definitions with hierarchical permissions
  @roles %{
    "admin" => %{
      permissions: [
        # Cluster management
        "cluster:create",
        "cluster:read",
        "cluster:update",
        "cluster:delete",
        "cluster:failover",
        "cluster:scale",
        "cluster:config",

        # Job management
        "job:create",
        "job:read",
        "job:update",
        "job:delete",
        "job:cancel",
        "job:restart",
        "job:priority",

        # Image management
        "image:build",
        "image:read",
        "image:deploy",
        "image:delete",
        "image:scan",
        "image:rollback",
        "image:config",

        # Alert management
        "alert:create",
        "alert:read",
        "alert:update",
        "alert:delete",
        "alert:acknowledge",
        "alert:resolve",
        "alert:escalate",

        # Security and audit
        "security:read",
        "security:config",
        "audit:read",
        "audit:export",

        # System administration
        "system:config",
        "system:metrics",
        "system:health"
      ],
      description: "Full system administrator access"
    },
    "operator" => %{
      permissions: [
        # Read access to all resources
        "cluster:read",
        "job:read",
        "image:read",
        "alert:read",

        # Job operations
        "job:create",
        "job:cancel",
        "job:restart",

        # Alert operations
        "alert:acknowledge",
        "alert:resolve",

        # Image operations
        "image:deploy",
        "image:rollback",

        # Basic cluster operations
        "cluster:scale",
        "cluster:failover",

        # Monitoring access
        "system:metrics",
        "system:health"
      ],
      description: "Operations team access for day-to-day management"
    },
    "developer" => %{
      permissions: [
        # Read access
        "cluster:read",
        "job:read",
        "image:read",
        "alert:read",

        # Job management
        "job:create",
        "job:cancel",

        # Image operations
        "image:build",
        "image:scan",

        # Monitoring
        "system:metrics"
      ],
      description: "Developer access for application deployment and monitoring"
    },
    "viewer" => %{
      permissions: [
        "cluster:read",
        "job:read",
        "image:read",
        "alert:read",
        "system:metrics",
        "system:health"
      ],
      description: "Read-only access for monitoring and reporting"
    }
  }

  # Resource ownership and context-based permissions
  defstruct [
    :users,
    :roles,
    :policies,
    :sessions,
    :contexts,
    :auth_adapter
  ]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init(opts) do
    clean_opts = if is_list(opts), do: Keyword.delete(opts, :name), else: opts
    auth_adapter = Keyword.get(clean_opts, :auth_adapter)

    state = %__MODULE__{
      users: %{},
      roles: @roles,
      policies: %{},
      sessions: %{},
      contexts: %{},
      auth_adapter: auth_adapter
    }

    Logger.info("RBAC system initialized with #{map_size(@roles)} roles")
    {:ok, state}
  end

  # Public API

  def authenticate_user(username, password, opts \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:authenticate, username, password, opts})
  end

  def create_session(user_id, metadata \\ %{}, server \\ __MODULE__) do
    GenServer.call(server, {:create_session, user_id, metadata})
  end

  def authorize(session_id, resource, action, context \\ %{}, server \\ __MODULE__) do
    GenServer.call(server, {:authorize, session_id, resource, action, context})
  end

  def assign_role(user_id, role, context \\ %{}, server \\ __MODULE__) do
    GenServer.call(server, {:assign_role, user_id, role, context})
  end

  def revoke_role(user_id, role, context \\ %{}, server \\ __MODULE__) do
    GenServer.call(server, {:revoke_role, user_id, role, context})
  end

  def get_user_permissions(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:get_permissions, user_id})
  end

  def create_policy(policy_name, policy_spec, server \\ __MODULE__) do
    GenServer.call(server, {:create_policy, policy_name, policy_spec})
  end

  def list_sessions(filter \\ %{}, server \\ __MODULE__) do
    GenServer.call(server, {:list_sessions, filter})
  end

  def revoke_session(session_id, reason \\ "manual_revocation", server \\ __MODULE__) do
    GenServer.call(server, {:revoke_session, session_id, reason})
  end

  # GenServer callbacks

  def handle_call({:authenticate, username, password, opts}, _from, state) do
    case authenticate_user_impl(username, password, opts, state) do
      {:ok, user} ->
        user_id = user.id
        updated_state = put_in(state.users[user_id], user)

        AuditLogger.log_auth_event(%{
          event: "user_authenticated",
          user_id: user_id,
          username: username,
          timestamp: DateTime.utc_now(),
          metadata: Map.take(opts, [:ip_address, :user_agent])
        })

        {:reply, {:ok, user}, updated_state}

      {:error, reason} ->
        AuditLogger.log_auth_event(%{
          event: "authentication_failed",
          username: username,
          reason: reason,
          timestamp: DateTime.utc_now(),
          metadata: Map.take(opts, [:ip_address, :user_agent])
        })

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:create_session, user_id, metadata}, _from, state) do
    case Map.get(state.users, user_id) do
      nil ->
        {:reply, {:error, :user_not_found}, state}

      user ->
        session_id = generate_session_id()

        session = %{
          id: session_id,
          user_id: user_id,
          user: user,
          created_at: DateTime.utc_now(),
          last_activity: DateTime.utc_now(),
          metadata: metadata,
          active: true
        }

        updated_state = put_in(state.sessions[session_id], session)

        AuditLogger.log_auth_event(%{
          event: "session_created",
          user_id: user_id,
          session_id: session_id,
          timestamp: DateTime.utc_now()
        })

        {:reply, {:ok, session_id}, updated_state}
    end
  end

  def handle_call({:authorize, session_id, resource, action, context}, _from, state) do
    case get_session(state, session_id) do
      {:ok, session} ->
        permission = "#{resource}:#{action}"
        user = session.user

        authorized = authorized?(user, permission, context, state)

        # Update session activity
        updated_session = put_in(session.last_activity, DateTime.utc_now())
        updated_state = put_in(state.sessions[session_id], updated_session)

        # Log authorization attempt
        AuditLogger.log_auth_event(%{
          event: "authorization_check",
          user_id: user.id,
          session_id: session_id,
          resource: resource,
          action: action,
          permission: permission,
          authorized: authorized,
          context: context,
          timestamp: DateTime.utc_now()
        })

        {:reply, {:ok, authorized}, updated_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:assign_role, user_id, role, context}, _from, state) do
    case {Map.get(state.users, user_id), Map.get(state.roles, role)} do
      {nil, _} ->
        {:reply, {:error, :user_not_found}, state}

      {_, nil} ->
        {:reply, {:error, :role_not_found}, state}

      {user, _role_spec} ->
        updated_roles = [role | user.roles || []] |> Enum.uniq()
        updated_user = Map.put(user, :roles, updated_roles)
        updated_state = put_in(state.users[user_id], updated_user)

        AuditLogger.log_auth_event(%{
          event: "role_assigned",
          user_id: user_id,
          role: role,
          context: context,
          timestamp: DateTime.utc_now()
        })

        {:reply, :ok, updated_state}
    end
  end

  def handle_call({:revoke_role, user_id, role, context}, _from, state) do
    case Map.get(state.users, user_id) do
      nil ->
        {:reply, {:error, :user_not_found}, state}

      user ->
        updated_roles = (user.roles || []) |> Enum.reject(&(&1 == role))
        updated_user = Map.put(user, :roles, updated_roles)
        updated_state = put_in(state.users[user_id], updated_user)

        AuditLogger.log_auth_event(%{
          event: "role_revoked",
          user_id: user_id,
          role: role,
          context: context,
          timestamp: DateTime.utc_now()
        })

        {:reply, :ok, updated_state}
    end
  end

  def handle_call({:get_permissions, user_id}, _from, state) do
    case Map.get(state.users, user_id) do
      nil ->
        {:reply, {:error, :user_not_found}, state}

      user ->
        permissions = get_user_permissions_impl(user, state)
        {:reply, {:ok, permissions}, state}
    end
  end

  def handle_call({:create_policy, policy_name, policy_spec}, _from, state) do
    updated_state = put_in(state.policies[policy_name], policy_spec)

    AuditLogger.log_auth_event(%{
      event: "policy_created",
      policy_name: policy_name,
      policy_spec: policy_spec,
      timestamp: DateTime.utc_now()
    })

    {:reply, :ok, updated_state}
  end

  def handle_call({:list_sessions, filter}, _from, state) do
    sessions =
      state.sessions
      |> Map.values()
      |> filter_sessions(filter)

    {:reply, {:ok, sessions}, state}
  end

  def handle_call({:revoke_session, session_id, reason}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :session_not_found}, state}

      session ->
        updated_session = Map.put(session, :active, false)
        updated_state = put_in(state.sessions[session_id], updated_session)

        AuditLogger.log_auth_event(%{
          event: "session_revoked",
          user_id: session.user_id,
          session_id: session_id,
          reason: reason,
          timestamp: DateTime.utc_now()
        })

        {:reply, :ok, updated_state}
    end
  end

  # Private implementation

  defp authenticate_user_impl(username, password, opts, state) do
    adapter = resolve_auth_adapter(state)
    invoke_auth_adapter(adapter, username, password, opts)
  end

  defp resolve_auth_adapter(state) do
    state.auth_adapter ||
      Application.get_env(:flame_apple_container_backend, :auth_adapter)
  end

  defp invoke_auth_adapter(nil, _username, _password, _opts) do
    Logger.warning(
      "No auth adapter configured. Set :auth_adapter in :flame_apple_container_backend app config " <>
        "or pass auth_adapter: option to start_link/1."
    )

    {:error, :auth_adapter_not_configured}
  end

  defp invoke_auth_adapter(adapter, username, password, opts) when is_function(adapter, 3) do
    adapter.(username, password, opts)
  end

  defp invoke_auth_adapter(adapter, username, password, opts) when is_atom(adapter) do
    adapter.authenticate(username, password, opts)
  end

  defp get_session(state, session_id) do
    case Map.get(state.sessions, session_id) do
      nil -> {:error, :session_not_found}
      %{active: false} -> {:error, :session_inactive}
      session -> {:ok, session}
    end
  end

  defp authorized?(user, permission, context, state) do
    user_permissions = get_user_permissions_impl(user, state)

    # Check direct permission
    direct_permission = permission in user_permissions

    # Check context-based policies
    policy_permission = evaluate_policies(user, permission, context, state)

    # Check resource ownership
    ownership_permission = check_resource_ownership(user, permission, context)

    direct_permission or policy_permission or ownership_permission
  end

  defp get_user_permissions_impl(user, state) do
    user.roles
    |> Enum.flat_map(fn role ->
      case Map.get(state.roles, role) do
        nil -> []
        role_spec -> role_spec.permissions
      end
    end)
    |> Enum.uniq()
  end

  defp evaluate_policies(user, permission, context, state) do
    state.policies
    |> Enum.any?(fn {_name, policy} ->
      evaluate_policy(policy, user, permission, context)
    end)
  end

  defp evaluate_policy(policy, user, _permission, context) do
    # Simple policy evaluation - in production this would be more sophisticated
    case policy do
      %{type: "resource_owner", resource: resource} ->
        context_resource = Map.get(context, :resource_type)
        owner_id = Map.get(context, :owner_id)

        context_resource == resource and owner_id == user.id

      %{type: "time_based", start_hour: start_h, end_hour: end_h} ->
        current_hour = DateTime.utc_now().hour
        current_hour >= start_h and current_hour <= end_h

      _ ->
        false
    end
  end

  defp check_resource_ownership(user, permission, context) do
    case {permission, Map.get(context, :owner_id)} do
      {perm, owner_id} when perm in ["job:read", "job:update", "job:delete"] ->
        owner_id == user.id

      {perm, owner_id} when perm in ["image:read", "image:update", "image:delete"] ->
        owner_id == user.id

      _ ->
        false
    end
  end

  defp filter_sessions(sessions, filter) do
    Enum.filter(sessions, fn session ->
      Enum.all?(filter, &session_matches_filter?(session, &1))
    end)
  end

  defp session_matches_filter?(session, {:active, value}), do: session.active == value
  defp session_matches_filter?(session, {:user_id, value}), do: session.user_id == value

  defp session_matches_filter?(session, {:created_after, value}),
    do: DateTime.compare(session.created_at, value) != :lt

  defp session_matches_filter?(session, {:created_before, value}),
    do: DateTime.compare(session.created_at, value) != :gt

  defp session_matches_filter?(_session, {_key, _value}), do: true

  defp generate_session_id do
    :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)
  end

  # Utility functions for integration

  def require_permission(session_id, resource, action, context \\ %{}, server \\ __MODULE__) do
    case authorize(session_id, resource, action, context, server) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  def with_authorization(session_id, resource, action, context \\ %{}, server \\ __MODULE__, fun) do
    case require_permission(session_id, resource, action, context, server) do
      :ok -> fun.()
      error -> error
    end
  end
end
