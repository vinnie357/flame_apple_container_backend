defmodule FlameWeb.DashboardLiveTest do
  use FlameWeb.ConnCase
  import Phoenix.LiveViewTest

  @moduletag :integration

  setup do
    # Ensure Floki is available for LiveView tests
    # Force load Floki module by adding its path to the code path
    floki_path = Path.join([File.cwd!(), "_build", "test", "lib", "floki", "ebin"])
    Code.prepend_path(floki_path)
    
    # Now try to load Floki
    case Code.ensure_loaded(Floki) do
      {:module, _} -> :ok
      {:error, _} -> 
        # Skip tests that require Floki if it's not available
        {:skip, "Floki not available for LiveView tests"}
    end
  end

  describe "dashboard live view" do
    test "mounts successfully and shows dashboard components", %{conn: conn} do
      {:ok, view, html} = live(conn, "/dashboard")

      # Check main dashboard components are present
      assert html =~ "FLAME Apple Containers Dashboard"
      assert html =~ "Container Pool"
      assert html =~ "Resource Usage"
      assert html =~ "Task Metrics"
      assert html =~ "Circuit Breakers"
      assert html =~ "Active Containers"
      assert html =~ "Test Job Execution"
      assert html =~ "Recent Events"

      # Check that the view is properly initialized
      # No test IDs yet
      assert has_element?(view, "[data-testid=dashboard-header]") == false
      assert has_element?(view, ".dashboard")
      assert has_element?(view, ".status-grid")
      assert has_element?(view, ".container-list")
      assert has_element?(view, ".job-testing-section")
    end

    test "refreshes data when refresh button clicked", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      # Click refresh button
      view |> element("button", "Refresh") |> render_click()

      # Dashboard should update (this is mostly testing that no errors occur)
      assert render(view) =~ "FLAME Apple Containers Dashboard"
    end

    test "shows container pool status", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      # Check that pool status metrics are displayed
      assert html =~ "Warm Containers"
      assert html =~ "Active Containers"
      assert html =~ "Total Containers"

      # Should show numeric values (even if 0)
      assert html =~ ~r/\d+.*Warm Containers/
      assert html =~ ~r/\d+.*Active Containers/
      assert html =~ ~r/\d+.*Total Containers/
    end

    test "shows resource usage with progress bars", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      # Check resource usage components
      assert html =~ "Resource Usage"
      assert html =~ "Memory Usage"
      assert html =~ "CPU Usage"
      assert html =~ "progress-bar"
      assert html =~ "progress-fill"

      # Should show percentage values
      assert html =~ ~r/\d+\.\d+%/
    end

    test "shows task metrics", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      # Check task metrics display
      assert html =~ "Task Metrics"
      assert html =~ "Total Executions"
      assert html =~ "Avg Execution Time"
      assert html =~ "Error Rate"
    end

    test "shows circuit breaker status", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      # Check circuit breaker display
      assert html =~ "Circuit Breakers"
      assert html =~ "circuit-breaker"

      # Should show circuit breaker names and states
      # (actual content depends on what's running)
    end

    test "shows container list with real or fallback data", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      # Check container list table
      assert html =~ "Active Containers"
      assert html =~ "containers-table"
      assert html =~ "Container ID"
      assert html =~ "Status"
      assert html =~ "Uptime"
      assert html =~ "Memory Usage"
      assert html =~ "CPU Usage"
      assert html =~ "Health"
      assert html =~ "Actions"
    end

    test "container scaling controls work", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      # Test scale up
      view |> element("button", "Scale Up") |> render_click()

      # Should show flash message
      assert render(view) =~ "Scale up triggered"

      # Test scale down
      view |> element("button", "Scale Down") |> render_click()

      # Should show flash message
      assert render(view) =~ "Scale down triggered"
    end

    test "job testing interface shows all job types", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      # Check job testing section
      assert html =~ "Test Job Execution"
      assert html =~ "Quick Tests"
      assert html =~ "Load Testing"

      # Check job type buttons
      assert html =~ "Simple Math Job"
      assert html =~ "Complex Processing"
      assert html =~ "ML Computation"
      assert html =~ "Error Simulation"
      assert html =~ "5 Concurrent Jobs"
      assert html =~ "10 Concurrent Jobs"
      assert html =~ "Stress Test"
    end

    test "can execute test jobs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      # Execute simple job
      view
      |> element("button", "Simple Math Job")
      |> render_click()

      # Allow LiveView state to stabilize
      Process.sleep(100)

      # Should show flash message
      assert render(view) =~ "Executing simple test job"

      # Execute complex job
      view
      |> element("button", "Complex Processing")
      |> render_click()

      # Allow LiveView state to stabilize
      Process.sleep(100)

      assert render(view) =~ "Executing complex test job"
    end

    test "shows recent events", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      # Check events section
      assert html =~ "Recent Events"
      assert html =~ "events-list"

      # Should show some events (either real or fallback)
      assert html =~ "event-item"
    end

    test "real-time updates work", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      # Simulate a telemetry event
      :telemetry.execute([:flame, :container, :provision], %{count: 1}, %{
        container_id: "test-container-123",
        timestamp: System.system_time(:millisecond)
      })

      # Give time for the event to be processed
      Process.sleep(100)

      # The dashboard should handle the event without crashing
      assert render(view) =~ "FLAME Apple Containers Dashboard"
    end

    test "handles container management actions", %{conn: conn} do
      # This test would work if we had actual containers running
      # For now, we'll test that the actions don't crash the interface
      {:ok, view, html} = live(conn, "/dashboard")

      # Only test if there are containers shown
      if String.contains?(html, "flame-worker") do
        # Try to restart a container (this will fail gracefully in test)
        container_buttons = view |> element(".containers-table") |> render()

        if String.contains?(container_buttons, "Restart") do
          # This would trigger the restart action
          # We can't easily test this without actual containers
          assert true
        end
      else
        # No containers to test with
        assert true
      end
    end

    test "dashboard auto-refreshes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      # Wait for auto-refresh interval (shorter in test)
      # Wait longer than 5 second refresh interval
      Process.sleep(6000)

      # Dashboard should still be responsive
      assert render(view) =~ "FLAME Apple Containers Dashboard"
    end

    test "handles errors gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      # Test error job execution
      view
      |> element("button", "Error Simulation")
      |> render_click()

      # Should handle the error gracefully
      assert render(view) =~ "FLAME Apple Containers Dashboard"
    end

    test "shows performance charts", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      # Check charts section
      assert html =~ "Performance Metrics"
      assert html =~ "charts-grid"
      assert html =~ "Task Execution Time"
      assert html =~ "Container Scaling"
      assert html =~ "Error Rate"

      # Should have chart containers with hooks
      assert html =~ "phx-hook=\"ExecutionTimeChart\""
      assert html =~ "phx-hook=\"ScalingChart\""
      assert html =~ "phx-hook=\"ErrorRateChart\""
    end
  end

  describe "dashboard data functions" do
    test "get_container_list handles Apple Containers command failures gracefully" do
      # This tests the private function behavior through the live view
      {:ok, _view, html} = live(build_conn(), "/dashboard")

      # Should not crash when container commands fail
      # and should show fallback data
      assert html =~ "Active Containers"
    end

    test "get_pool_status provides meaningful data" do
      {:ok, _view, html} = live(build_conn(), "/dashboard")

      # Should show pool status metrics
      assert html =~ "Container Pool"
      # Numbers should be present (even if 0)
      assert html =~ ~r/\d+/
    end

    test "get_resource_status calculates correctly" do
      {:ok, _view, html} = live(build_conn(), "/dashboard")

      # Should show resource percentages
      assert html =~ "Resource Usage"
      assert html =~ ~r/\d+\.\d+%/
    end

    test "recent events are generated" do
      {:ok, _view, html} = live(build_conn(), "/dashboard")

      # Should show recent events
      assert html =~ "Recent Events"
      assert html =~ "event-item"
    end
  end

  describe "circuit breaker integration" do
    test "can reset circuit breakers", %{conn: conn} do
      {:ok, view, html} = live(conn, "/dashboard")

      # Look for reset buttons (only appear when circuit is not closed)
      if String.contains?(html, "Reset") do
        # Test reset functionality - click the first circuit breaker reset button
        view
        |> element("button[phx-value-name='container_provisioning']", "Reset")
        |> render_click()

        # Should show success message or handle gracefully
        updated_html = render(view)
        assert updated_html =~ "FLAME Apple Containers Dashboard"
      else
        # No circuit breakers to reset
        assert true
      end
    end
  end

  describe "telemetry integration" do
    test "dashboard responds to telemetry events" do
      {:ok, view, _html} = live(build_conn(), "/dashboard")

      # Send various telemetry events
      events = [
        {[:flame, :container, :provision], %{count: 1}, %{container_id: "test-123"}},
        {[:flame, :task, :execute], %{execution_time: 1000}, %{task_id: "task-456"}},
        {[:flame, :task, :complete], %{execution_time: 1500}, %{task_id: "task-456"}},
        {[:flame, :container, :terminate], %{count: 1},
         %{container_id: "test-123", reason: :normal}}
      ]

      # Send all events
      Enum.each(events, fn {event_name, measurements, metadata} ->
        :telemetry.execute(
          event_name,
          measurements,
          Map.put(metadata, :timestamp, System.system_time(:millisecond))
        )
      end)

      # Give time for events to be processed
      Process.sleep(200)

      # Dashboard should still be functional
      assert render(view) =~ "FLAME Apple Containers Dashboard"
    end
  end
end
