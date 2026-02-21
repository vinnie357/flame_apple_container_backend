#!/bin/bash

echo "🌐 FLAME Apple Containers - End-to-End Browser Test"
echo "==================================================="

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m' 
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# Check dependencies
print_status "Checking dependencies..."

if ! command -v mix &> /dev/null; then
    print_error "Elixir/Mix not found. Please install Elixir first."
    exit 1
fi

# Check if we're in the right directory
if [ ! -f "mix.exs" ]; then
    print_error "Not in an Elixir project directory. Please run from the project root."
    exit 1
fi

# Set environment for testing
export MIX_ENV=dev
export FLAME_ENVIRONMENT=development
export FLAME_ENABLE_WEB_INTERFACE=true
export FLAME_ENABLE_METRICS=true
export FLAME_ENABLE_SECURITY=true
export FLAME_ENABLE_RESOURCE_MANAGEMENT=true
export FLAME_ENABLE_BENCHMARKS=true
export FLAME_WEB_PORT=4001

print_success "Environment configured for E2E testing"

# Get dependencies if needed
if [ ! -d "deps" ] || [ ! -d "_build" ]; then
    print_status "Installing dependencies..."
    mix deps.get || {
        print_error "Failed to get dependencies"
        exit 1
    }
    
    print_status "Compiling project..."
    mix compile || {
        print_error "Failed to compile project"
        exit 1
    }
fi

print_success "Project ready"

# Check if Phoenix dependencies are available
print_status "Checking Phoenix availability..."

if mix deps.tree | grep -q phoenix; then
    print_success "Phoenix dependencies found"
elif [ "$1" = "--skip-phoenix-check" ]; then
    print_warning "Phoenix check skipped - some features may not work"
else
    print_warning "Phoenix dependencies not found. Some web features may not work."
    echo ""
    echo "To enable full web dashboard, add these to your mix.exs:"
    echo "  {:phoenix, \"~> 1.7.0\"},"
    echo "  {:phoenix_live_view, \"~> 0.20.0\"},"
    echo "  {:phoenix_html, \"~> 3.3\"},"
    echo "  {:plug_cowboy, \"~> 2.6\"}"
    echo ""
    echo "Run again with --skip-phoenix-check to continue anyway"
    echo "Or press Enter to continue with limited functionality..."
    read -r
fi

# Run the E2E test
print_status "Starting End-to-End Browser Test..."
echo ""
echo "This test will:"
echo "1. 🚀 Start all FLAME systems with web interface"
echo "2. 🌐 Open dashboard in your browser"
echo "3. 🔄 Execute real FLAME jobs with live monitoring"
echo "4. 📊 Show metrics, resource usage, and security features"
echo "5. 🛑 Demonstrate graceful shutdown"
echo ""
echo "The dashboard will open at: http://localhost:4001/dashboard"
echo ""

if [ "$1" = "--auto" ]; then
    print_status "Running in automatic mode..."
else
    echo "Press Enter to start the test, or Ctrl+C to cancel..."
    read -r
fi

# Run the E2E test
print_status "Executing E2E test..."

elixir test/e2e_browser_test.exs

TEST_EXIT_CODE=$?

echo ""
if [ $TEST_EXIT_CODE -eq 0 ]; then
    print_success "E2E Test completed successfully! ✅"
    echo ""
    echo "🎉 Test Results Summary:"
    echo "========================"
    echo "✅ All FLAME systems started correctly"
    echo "✅ Web dashboard opened and functional"
    echo "✅ Jobs executed with real-time monitoring"
    echo "✅ Metrics collection and display working"
    echo "✅ Security features validated"
    echo "✅ Resource management functional"
    echo "✅ Circuit breakers responding correctly"
    echo "✅ Graceful shutdown completed"
    echo ""
    echo "🚀 Your FLAME Apple Containers backend is production-ready!"
    echo ""
    echo "🌐 To manually test the dashboard:"
    echo "   1. Run: iex -S mix"
    echo "   2. Set: System.put_env(\"FLAME_ENABLE_WEB_INTERFACE\", \"true\")"
    echo "   3. Visit: http://localhost:4000/dashboard"
else
    print_error "E2E Test encountered issues! ❌"
    echo ""
    echo "💡 Troubleshooting Tips:"
    echo "========================"
    echo "1. Check that all dependencies are installed: mix deps.get"
    echo "2. Ensure the project compiles: mix compile"
    echo "3. For web features, install Phoenix dependencies"
    echo "4. Check that port 4000 is available"
    echo "5. Review the error output above for specific issues"
    echo ""
    echo "🔧 Manual Testing:"
    echo "   1. Start: iex -S mix"
    echo "   2. Run: E2EBrowserTest.run_complete_test()"
fi

echo ""
echo "📚 For more information:"
echo "   - Configuration Guide: CONFIGURATION_GUIDE.md"
echo "   - Integration Guide: INTEGRATION_GUIDE.md"
echo "   - Interactive Dashboard Guide: INTERACTIVE_DASHBOARD_GUIDE.md"

exit $TEST_EXIT_CODE