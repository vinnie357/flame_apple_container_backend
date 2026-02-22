#!/bin/bash
# Health check script for FLAME worker containers
# This script verifies that the Erlang VM and FLAME worker are healthy

set -e

# Configuration
TIMEOUT=5
MAX_RETRIES=3

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[HEALTH-CHECK]${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}[HEALTH-CHECK]${NC} $1" >&2
}

error() {
    echo -e "${RED}[HEALTH-CHECK]${NC} $1" >&2
}

# Check if EPMD is running and responding
check_epmd() {
    log "Checking EPMD daemon..."

    if ! command -v epmd >/dev/null 2>&1; then
        error "EPMD command not found"
        return 1
    fi

    # Check if EPMD is responding to -names query
    if timeout $TIMEOUT epmd -names >/dev/null 2>&1; then
        log "EPMD daemon is responding"
        return 0
    else
        error "EPMD daemon is not responding"
        return 1
    fi
}

# Check if the Erlang node is running
check_erlang_node() {
    log "Checking Erlang node..."

    # Get the node name from environment or use default
    NODE_NAME=${RELEASE_NODE:-"worker@worker.flame.local"}

    # Use erl_call to ping the node
    if command -v erl_call >/dev/null 2>&1; then
        if timeout $TIMEOUT erl_call -n "$NODE_NAME" -e "erlang:system_info(system_version)" >/dev/null 2>&1; then
            log "Erlang node $NODE_NAME is responding"
            return 0
        else
            warn "Erlang node $NODE_NAME is not responding via erl_call"
        fi
    fi

    # Fallback: check if beam process is running
    if pgrep -f "beam" >/dev/null 2>&1; then
        log "Beam process is running"
        return 0
    else
        error "No beam process found"
        return 1
    fi
}

# Check basic system health
check_system_health() {
    log "Checking system health..."

    # Check memory usage (warn if over 90%)
    if command -v free >/dev/null 2>&1; then
        MEMORY_USAGE=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100.0}')
        if [ "$MEMORY_USAGE" -gt 90 ]; then
            warn "High memory usage: ${MEMORY_USAGE}%"
        else
            log "Memory usage: ${MEMORY_USAGE}%"
        fi
    fi

    # Check if we can create temporary files
    TEMP_FILE="/tmp/health-check-$$"
    if echo "test" > "$TEMP_FILE" 2>/dev/null && rm -f "$TEMP_FILE" 2>/dev/null; then
        log "Filesystem is writable"
    else
        error "Cannot write to filesystem"
        return 1
    fi

    return 0
}

# Check if FLAME application is loaded
check_flame_application() {
    log "Checking FLAME application..."

    NODE_NAME=${RELEASE_NODE:-"worker@worker.flame.local"}

    # Try to check if FLAME application is loaded
    if command -v erl_call >/dev/null 2>&1; then
        if timeout $TIMEOUT erl_call -n "$NODE_NAME" -e "application:which_applications()" 2>/dev/null | grep -q "flame"; then
            log "FLAME application is loaded"
            return 0
        else
            warn "FLAME application may not be loaded"
        fi
    fi

    # If we can't verify FLAME specifically, consider it healthy if Erlang is running
    return 0
}

# Main health check function
main() {
    log "Starting health check for FLAME worker container..."

    local exit_code=0

    # Run all health checks
    if ! check_system_health; then
        exit_code=1
    fi

    if ! check_epmd; then
        exit_code=1
    fi

    if ! check_erlang_node; then
        exit_code=1
    fi

    if ! check_flame_application; then
        # FLAME check is not critical for basic health
        warn "FLAME application check failed, but continuing..."
    fi

    if [ $exit_code -eq 0 ]; then
        log "Health check passed - container is healthy"
    else
        error "Health check failed - container is unhealthy"
    fi

    return $exit_code
}

# Handle script arguments
case "${1:-}" in
    --verbose|-v)
        set -x
        main
        ;;
    --quiet|-q)
        main >/dev/null 2>&1
        ;;
    --help|-h)
        echo "Usage: $0 [--verbose|-v] [--quiet|-q] [--help|-h]"
        echo "  --verbose, -v: Enable verbose output"
        echo "  --quiet, -q:   Suppress all output"
        echo "  --help, -h:    Show this help message"
        exit 0
        ;;
    *)
        main
        ;;
esac
