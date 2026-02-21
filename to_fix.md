# Failing Tests to Fix

## Dashboard Live View Tests (FlameWeb.DashboardLiveTest)
1. test dashboard live view shows performance charts - `test/flame_web/live/dashboard_live_test.exs`
2. test dashboard live view dashboard auto-refreshes - `test/flame_web/live/dashboard_live_test.exs`
3. test dashboard live view shows circuit breaker status - `test/flame_web/live/dashboard_live_test.exs`
4. test dashboard live view refreshes data when refresh button clicked - `test/flame_web/live/dashboard_live_test.exs`
5. test dashboard live view shows resource usage with progress bars - `test/flame_web/live/dashboard_live_test.exs`
6. test dashboard live view real-time updates work - `test/flame_web/live/dashboard_live_test.exs`
7. test dashboard live view handles errors gracefully - `test/flame_web/live/dashboard_live_test.exs`
8. test circuit breaker integration can reset circuit breakers - `test/flame_web/live/dashboard_live_test.exs`
9. test telemetry integration dashboard responds to telemetry events - `test/flame_web/live/dashboard_live_test.exs`
10. test dashboard live view mounts successfully and shows dashboard components - `test/flame_web/live/dashboard_live_test.exs`
11. test dashboard data functions get_pool_status provides meaningful data - `test/flame_web/live/dashboard_live_test.exs`
12. test dashboard live view shows task metrics - `test/flame_web/live/dashboard_live_test.exs`
13. test dashboard data functions recent events are generated - `test/flame_web/live/dashboard_live_test.exs`
14. test dashboard live view shows container list with real or fallback data - `test/flame_web/live/dashboard_live_test.exs`
15. test dashboard live view shows container pool status - `test/flame_web/live/dashboard_live_test.exs`
16. test dashboard live view can execute test jobs - `test/flame_web/live/dashboard_live_test.exs`
17. test dashboard live view shows recent events - `test/flame_web/live/dashboard_live_test.exs`
18. test dashboard data functions get_resource_status calculates correctly - `test/flame_web/live/dashboard_live_test.exs`
19. test dashboard live view handles container management actions - `test/flame_web/live/dashboard_live_test.exs`
20. test dashboard data functions get_container_list handles Apple Containers command failures gracefully - `test/flame_web/live/dashboard_live_test.exs`
21. test dashboard live view container scaling controls work - `test/flame_web/live/dashboard_live_test.exs`
22. test dashboard live view job testing interface shows all job types - `test/flame_web/live/dashboard_live_test.exs`

## Other Tests
23. test container scaling functionality dashboard scaling events trigger correctly - `test/flame/scaling_test.exs` (FLAME.ScalingTest)
24. test System resilience handles component restart scenarios - `test/flame/apple_containers/integration_test.exs` (FLAME.AppleContainers.IntegrationTest)
25. test Pool scaling scales pool up within limits - `test/flame/apple_containers/manager_test.exs` (FLAME.AppleContainers.ManagerTest)

## Test Files
- `test/flame_web/live/dashboard_live_test.exs` - 22 failing tests
- `test/flame/scaling_test.exs` - 1 failing test
- `test/flame/apple_containers/integration_test.exs` - 1 failing test
- `test/flame/apple_containers/manager_test.exs` - 1 failing test

## Total: 25 failing tests

### Main Issue Categories:
1. **Dashboard Live View Issues (22 tests)**: Most failing tests are related to Phoenix LiveView DOM loading issues, likely due to missing FlokiJS or DOM parsing dependencies
2. **Integration Tests (1 test)**: Component restart scenarios
3. **Manager Tests (1 test)**: Pool scaling functionality
4. **Scaling Tests (1 test)**: Dashboard scaling events