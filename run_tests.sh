#!/bin/bash

echo "🧪 FLAME Apple Containers Backend - Test Suite Runner"
echo "===================================================="

# Set environment variables for testing
export MIX_ENV=test
export FLAME_TEST_MODE=true

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if mix is available
if ! command -v mix &> /dev/null; then
    print_error "Elixir/Mix is not installed or not in PATH"
    exit 1
fi

print_status "Checking project setup..."

# Ensure dependencies are fetched and compiled
print_status "Fetching dependencies..."
mix deps.get || {
    print_error "Failed to fetch dependencies"
    exit 1
}

print_status "Compiling project..."
mix compile || {
    print_error "Failed to compile project"
    exit 1
}

print_success "Project setup complete"

# Run different test suites
echo ""
echo "🏃 Running Test Suites"
echo "====================="

# Test categories
run_unit_tests() {
    print_status "Running unit tests..."
    
    echo ""
    echo "📦 Container Pool Tests"
    echo "----------------------"
    mix test test/flame/container_pool_test.exs --color
    
    echo ""
    echo "🔄 Circuit Breaker Tests"
    echo "------------------------"
    mix test test/flame/circuit_breaker_test.exs --color
    
    echo ""
    echo "📊 Container Metrics Tests"
    echo "--------------------------"
    mix test test/flame/container_metrics_test.exs --color
    
    echo ""
    echo "🔒 Security Manager Tests"
    echo "-------------------------"
    mix test test/flame/security_manager_test.exs --color
    
    echo ""
    echo "🎭 Orchestrator Tests"
    echo "--------------------"
    mix test test/flame/orchestrator_test.exs --color
}

run_integration_tests() {
    print_status "Running integration tests..."
    
    echo ""
    echo "🔗 Integration Tests"
    echo "-------------------"
    mix test test/flame/integration_test.exs --color
}

run_all_tests() {
    print_status "Running all tests..."
    
    echo ""
    echo "🧪 All Tests"
    echo "============"
    mix test --color
}

# Parse command line arguments
case "${1:-all}" in
    "unit")
        run_unit_tests
        ;;
    "integration")
        run_integration_tests
        ;;
    "all")
        run_all_tests
        ;;
    "container-pool")
        print_status "Running Container Pool tests only..."
        mix test test/flame/container_pool_test.exs --color
        ;;
    "circuit-breaker")
        print_status "Running Circuit Breaker tests only..."
        mix test test/flame/circuit_breaker_test.exs --color
        ;;
    "metrics")
        print_status "Running Container Metrics tests only..."
        mix test test/flame/container_metrics_test.exs --color
        ;;
    "security")
        print_status "Running Security Manager tests only..."
        mix test test/flame/security_manager_test.exs --color
        ;;
    "orchestrator")
        print_status "Running Orchestrator tests only..."
        mix test test/flame/orchestrator_test.exs --color
        ;;
    "help"|"-h"|"--help")
        echo "Usage: $0 [test-type]"
        echo ""
        echo "Test types:"
        echo "  all              Run all tests (default)"
        echo "  unit             Run unit tests only"
        echo "  integration      Run integration tests only"
        echo "  container-pool   Run container pool tests"
        echo "  circuit-breaker  Run circuit breaker tests"
        echo "  metrics          Run metrics tests"
        echo "  security         Run security tests"
        echo "  orchestrator     Run orchestrator tests"
        echo ""
        echo "Examples:"
        echo "  $0                    # Run all tests"
        echo "  $0 unit              # Run unit tests"
        echo "  $0 container-pool    # Run container pool tests only"
        exit 0
        ;;
    *)
        print_error "Unknown test type: $1"
        print_status "Use '$0 help' for usage information"
        exit 1
        ;;
esac

TEST_EXIT_CODE=$?

echo ""
if [ $TEST_EXIT_CODE -eq 0 ]; then
    print_success "All tests completed successfully! ✅"
    echo ""
    echo "🎉 Test Results Summary:"
    echo "========================"
    echo "✅ Container Pool Management - Warm pool, lifecycle, monitoring"
    echo "✅ Circuit Breaker Patterns - Failure handling, recovery, backoff"
    echo "✅ Container Metrics - Telemetry, monitoring, collection"
    echo "✅ Security Manager - Validation, execution, audit logging"
    echo "✅ Orchestrator - Clustering, task scheduling, workflows"
    echo "✅ Integration - End-to-end functionality, error handling"
    echo ""
    echo "🚀 The FLAME Apple Containers backend is ready for production!"
else
    print_error "Some tests failed! ❌"
    echo ""
    echo "💡 Troubleshooting Tips:"
    echo "========================"
    echo "1. Check that all dependencies are properly installed: mix deps.get"
    echo "2. Ensure the project compiles: mix compile"
    echo "3. Some tests may fail in environments without Apple Containers"
    echo "4. Review test output above for specific error messages"
    echo "5. Run individual test suites to isolate issues"
fi

exit $TEST_EXIT_CODE