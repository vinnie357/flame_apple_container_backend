defmodule FlameWeb.DashboardRouter do
  @moduledoc """
  Dashboard router that selects the appropriate dashboard tier based on environment configuration.

  Supports three dashboard tiers:
  - minimal: Simple dashboard with basic FLAME backend status
  - standard: Full-featured dashboard with metrics and monitoring (default)
  - premium: Enterprise dashboard with advanced features and management

  Set via FLAME_DASHBOARD_TIER environment variable.
  """

  use Phoenix.LiveView
  require Logger

  import FlameWeb.CoreComponents

  @dashboard_tiers %{
    "minimal" => FlameWeb.SimpleDashboardLive,
    "standard" => FlameWeb.DashboardLive,
    "premium" => FlameWeb.EnterpriseDashboardLive
  }

  @default_tier "minimal"

  def mount(params, session, socket) do
    tier = get_dashboard_tier()
    dashboard_module = get_dashboard_module(tier)

    # Log which dashboard is being used
    require Logger
    Logger.info("Loading #{tier} dashboard (#{dashboard_module})")

    # Delegate to the appropriate dashboard module
    case dashboard_module.mount(params, session, socket) do
      {:ok, updated_socket} ->
        {:ok,
         assign(updated_socket,
           dashboard_tier: tier,
           dashboard_module: dashboard_module,
           page_title: get_page_title(tier)
         )}

      {:error, reason} ->
        # Fallback to minimal dashboard if the selected one fails
        Logger.warning(
          "Failed to load #{tier} dashboard: #{inspect(reason)}, falling back to minimal"
        )

        fallback_module = @dashboard_tiers["minimal"]

        case fallback_module.mount(params, session, socket) do
          {:ok, fallback_socket} ->
            {:ok,
             assign(fallback_socket,
               dashboard_tier: "minimal",
               dashboard_module: fallback_module,
               page_title: get_page_title("minimal"),
               fallback_notice: "Fell back to minimal dashboard due to: #{inspect(reason)}"
             )}

          fallback_error ->
            {:error, "All dashboards failed: #{inspect(fallback_error)}"}
        end
    end
  end

  def handle_params(params, uri, socket) do
    dashboard_module = socket.assigns.dashboard_module

    if function_exported?(dashboard_module, :handle_params, 3) do
      dashboard_module.handle_params(params, uri, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event(event, params, socket) do
    dashboard_module = socket.assigns.dashboard_module

    case event do
      "switch_dashboard_tier" ->
        handle_tier_switch(params, socket)

      _ ->
        if function_exported?(dashboard_module, :handle_event, 3) do
          dashboard_module.handle_event(event, params, socket)
        else
          {:noreply, socket}
        end
    end
  end

  def handle_info(message, socket) do
    dashboard_module = socket.assigns.dashboard_module

    if function_exported?(dashboard_module, :handle_info, 2) do
      dashboard_module.handle_info(message, socket)
    else
      {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="dashboard-wrapper">
      <!-- Dashboard Tier Indicator -->
      <div class="tier-indicator" style="position: fixed; top: 10px; right: 10px; z-index: 1000; background: rgba(0,0,0,0.8); color: white; padding: 8px 12px; border-radius: 6px; font-size: 12px;">
        <span>🔥 <%= String.upcase(@dashboard_tier) %></span>
        <%= if @dashboard_tier != "premium" do %>
          <button 
            phx-click="switch_dashboard_tier" 
            phx-value-tier="premium"
            style="margin-left: 8px; background: #3b82f6; color: white; border: none; padding: 2px 6px; border-radius: 3px; font-size: 10px; cursor: pointer;"
          >
            ⬆️ UPGRADE
          </button>
        <% end %>
        <%= if @dashboard_tier != "minimal" do %>
          <button 
            phx-click="switch_dashboard_tier" 
            phx-value-tier="minimal"
            style="margin-left: 4px; background: #6b7280; color: white; border: none; padding: 2px 6px; border-radius: 3px; font-size: 10px; cursor: pointer;"
          >
            ⬇️ SIMPLE
          </button>
        <% end %>
      </div>
      
      <!-- Fallback Notice -->
      <%= if assigns[:fallback_notice] do %>
        <div class="fallback-notice" style="background: #fef3c7; border: 1px solid #f59e0b; color: #92400e; padding: 12px; margin: 16px; border-radius: 6px; font-size: 14px;">
          ⚠️ <strong>Notice:</strong> <%= @fallback_notice %>
        </div>
      <% end %>
      
      <!-- Environment Configuration Info -->
      <div class="config-info" style="position: fixed; bottom: 10px; left: 10px; z-index: 1000; background: rgba(0,0,0,0.7); color: white; padding: 6px 10px; border-radius: 4px; font-size: 11px; font-family: monospace;">
        ENV: FLAME_DASHBOARD_TIER=<%= @dashboard_tier %>
      </div>
      
      <!-- Flash messages at router level -->
      <.flash_group flash={@flash} />
      
      <!-- Delegate to the selected dashboard -->
      <%= @dashboard_module.render(assigns) %>
    </div>
    """
  end

  # Private functions

  defp get_dashboard_tier do
    System.get_env("FLAME_DASHBOARD_TIER", @default_tier)
    |> String.downcase()
    |> validate_tier()
  end

  defp validate_tier(tier) when tier in ["minimal", "standard", "premium"], do: tier

  defp validate_tier(invalid_tier) do
    require Logger

    Logger.warning(
      "Invalid FLAME_DASHBOARD_TIER '#{invalid_tier}', using default '#{@default_tier}'"
    )

    @default_tier
  end

  defp get_dashboard_module(tier) do
    Map.get(@dashboard_tiers, tier, @dashboard_tiers[@default_tier])
  end

  defp get_page_title("minimal"), do: "FLAME - Minimal Dashboard"
  defp get_page_title("standard"), do: "FLAME - Standard Dashboard"
  defp get_page_title("premium"), do: "FLAME - Premium Enterprise Dashboard"
  defp get_page_title(_), do: "FLAME Dashboard"

  defp handle_tier_switch(%{"tier" => new_tier}, socket) do
    require Logger

    Logger.info(
      "Dashboard tier switch requested: #{socket.assigns.dashboard_tier} -> #{new_tier}"
    )

    # In a real application, you might want to:
    # 1. Update user preferences
    # 2. Check permissions for premium tier
    # 3. Store the preference in session/database

    socket =
      put_flash(
        socket,
        :info,
        "Dashboard tier switch requested to #{new_tier}. Refresh page or set FLAME_DASHBOARD_TIER=#{new_tier} environment variable."
      )

    {:noreply, socket}
  end
end
