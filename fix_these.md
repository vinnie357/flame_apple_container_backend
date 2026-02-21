# Failing Tests Categorized by Fix Priority

## Priority 1: Infrastructure Dependencies (1 test)
**Fix first - likely blocking other tests**

### DOM/Testing Dependencies
- **Issue**: Missing FlokiJS or Phoenix LiveView DOM parsing dependencies
- **Impact**: Blocks all LiveView tests from running
- **Fix**: Add missing test dependencies to mix.exs

## Priority 2: Core System Functionality (3 tests)
**Fix second - essential system features**

### Integration & Scaling
- System resilience handles component restart scenarios (`test/flame/apple_containers/integration_test.exs`)
- Pool scaling scales pool up within limits (`test/flame/apple_containers/manager_test.exs`)
- Container scaling functionality dashboard scaling events trigger correctly (`test/flame/scaling_test.exs`)

## Priority 3: Dashboard Core Features (5 tests)
**Fix third - basic dashboard functionality**

### Basic Dashboard Operations
- Dashboard live view mounts successfully and shows dashboard components (10)
- Dashboard live view shows container pool status (15)
- Dashboard live view shows container list with real or fallback data (14)
- Dashboard live view handles errors gracefully (7)
- Dashboard data functions get_pool_status provides meaningful data (11)

## Priority 4: Dashboard Data Functions (4 tests)
**Fix fourth - data retrieval and processing**

### Data Processing
- Dashboard data functions recent events are generated (13)
- Dashboard data functions get_resource_status calculates correctly (18)
- Dashboard data functions get_container_list handles Apple Containers command failures gracefully (20)
- Dashboard live view shows task metrics (12)

## Priority 5: Dashboard Interactive Features (6 tests)
**Fix fifth - user interactions**

### User Interface Interactions
- Dashboard live view refreshes data when refresh button clicked (4)
- Dashboard live view real-time updates work (6)
- Dashboard live view dashboard auto-refreshes (2)
- Dashboard live view handles container management actions (19)
- Dashboard live view container scaling controls work (21)
- Dashboard live view can execute test jobs (16)

## Priority 6: Dashboard Monitoring & Visualization (4 tests)
**Fix sixth - monitoring and charts**

### Monitoring Features
- Dashboard live view shows performance charts (1)
- Dashboard live view shows resource usage with progress bars (5)
- Dashboard live view shows circuit breaker status (3)
- Dashboard live view shows recent events (17)

## Priority 7: Dashboard Advanced Features (3 tests)
**Fix seventh - advanced functionality**

### Advanced Features
- Circuit breaker integration can reset circuit breakers (8)
- Telemetry integration dashboard responds to telemetry events (9)
- Dashboard live view job testing interface shows all job types (22)

## Summary by Priority Level
1. **Priority 1 (Infrastructure)**: 1 issue - Fix dependencies first
2. **Priority 2 (Core System)**: 3 tests - Essential system functionality
3. **Priority 3 (Dashboard Core)**: 5 tests - Basic dashboard features
4. **Priority 4 (Data Functions)**: 4 tests - Data processing
5. **Priority 5 (Interactive Features)**: 6 tests - User interactions
6. **Priority 6 (Monitoring)**: 4 tests - Monitoring and visualization
7. **Priority 7 (Advanced)**: 3 tests - Advanced features

## Test Files by Priority
1. **mix.exs** - Add missing dependencies (FlokiJS, DOM parsing)
2. **test/flame/apple_containers/integration_test.exs** - 1 test
3. **test/flame/apple_containers/manager_test.exs** - 1 test
4. **test/flame/scaling_test.exs** - 1 test
5. **test/flame_web/live/dashboard_live_test.exs** - 22 tests (grouped by priority)

## Root Cause Analysis
- **Primary Issue**: Missing FlokiJS dependency causing Phoenix LiveView DOM parsing to fail
- **Secondary Issues**: Core system scaling and integration functionality
- **Tertiary Issues**: Dashboard feature implementations

## Recommended Fix Strategy
1. **Add missing dependencies** to resolve DOM parsing issues
2. **Fix core system tests** to ensure base functionality works
3. **Fix dashboard tests** in priority order once dependencies are resolved

**Total: 25 failing tests**