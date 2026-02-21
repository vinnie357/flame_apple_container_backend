#!/bin/bash
# Worker initialization script for FLAME containers
# This script sets up the environment and starts the FLAME worker

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[WORKER-INIT]${NC} $1"
}

info() {
    echo -e "${BLUE}[WORKER-INIT]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WORKER-INIT]${NC} $1"
}

error() {
    echo -e "${RED}[WORKER-INIT]${NC} $1"
}

# Function to wait for a condition with timeout
wait_for() {
    local condition="$1"
    local timeout="${2:-30}"
    local interval="${3:-1}"
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        if eval "$condition"; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    return 1
}

# Setup environment variables
setup_environment() {
    log "Setting up environment..."
    
    # Set default values if not provided
    export MIX_ENV="${MIX_ENV:-prod}"
    export RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-name}"
    
    # Container networking setup
    export HOSTNAME="${HOSTNAME:-$(hostname)}"
    export FLAME_DNS_DOMAIN="${FLAME_DNS_DOMAIN:-flame.local}"
    
    # Node naming
    if [ -z "$RELEASE_NODE" ]; then
        if [ -n "$NODE_NAME" ]; then
            export RELEASE_NODE="$NODE_NAME"
        else
            export RELEASE_NODE="worker@${HOSTNAME}.${FLAME_DNS_DOMAIN}"
        fi
    fi
    
    # Erlang cookie
    if [ -n "$ERLANG_COOKIE" ]; then
        export RELEASE_COOKIE="$ERLANG_COOKIE"
    fi
    
    # EPMD configuration
    export ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-0.0.0.0}"
    export ERL_EPMD_PORT="${ERL_EPMD_PORT:-4369}"
    
    info "Environment configured:"
    info "  MIX_ENV: $MIX_ENV"
    info "  RELEASE_NODE: $RELEASE_NODE"
    info "  RELEASE_DISTRIBUTION: $RELEASE_DISTRIBUTION"
    info "  FLAME_DNS_DOMAIN: $FLAME_DNS_DOMAIN"
    info "  ERL_EPMD_ADDRESS: $ERL_EPMD_ADDRESS"
    info "  ERL_EPMD_PORT: $ERL_EPMD_PORT"
}

# Start EPMD daemon
start_epmd() {
    log "Starting EPMD daemon..."
    
    # Check if EPMD is already running
    if pgrep -f epmd >/dev/null 2>&1; then
        info "EPMD daemon is already running"
        return 0
    fi
    
    # Start EPMD
    epmd -daemon -address "$ERL_EPMD_ADDRESS" -port "$ERL_EPMD_PORT"
    
    # Wait for EPMD to be ready
    if wait_for "epmd -names >/dev/null 2>&1" 10 1; then
        log "EPMD daemon started successfully"
    else
        error "Failed to start EPMD daemon"
        return 1
    fi
}

# Setup networking and DNS
setup_networking() {
    log "Setting up networking..."
    
    # Add hostname resolution for container networking
    CONTAINER_IP=$(hostname -i 2>/dev/null || echo "127.0.0.1")
    info "Container IP: $CONTAINER_IP"
    
    # Ensure hostname resolves
    if ! nslookup "$HOSTNAME" >/dev/null 2>&1; then
        warn "Hostname $HOSTNAME does not resolve, using IP $CONTAINER_IP"
    fi
    
    # Test DNS resolution for the domain
    FULL_HOSTNAME="${HOSTNAME}.${FLAME_DNS_DOMAIN}"
    if nslookup "$FULL_HOSTNAME" >/dev/null 2>&1; then
        info "DNS resolution working for $FULL_HOSTNAME"
    else
        warn "DNS resolution failed for $FULL_HOSTNAME - distributed Erlang may not work"
    fi
}

# Validate configuration
validate_configuration() {
    log "Validating configuration..."
    
    # Check required environment variables
    if [ -z "$RELEASE_NODE" ]; then
        error "RELEASE_NODE is not set"
        return 1
    fi
    
    # Validate node name format
    if ! echo "$RELEASE_NODE" | grep -q "@"; then
        error "RELEASE_NODE must be in format name@host: $RELEASE_NODE"
        return 1
    fi
    
    # Check if release exists
    if [ ! -f "/app/bin/worker" ]; then
        error "Worker release not found at /app/bin/worker"
        return 1
    fi
    
    log "Configuration validation passed"
}

# Start the FLAME worker
start_worker() {
    log "Starting FLAME worker..."
    
    # Set runtime configuration
    export RELEASE_PROG="/app/bin/worker"
    
    # Additional Erlang VM options for container environment
    EXTRA_ERL_FLAGS="+K true +A 4 +SDio 4"
    if [ -n "$ERL_MAX_PORTS" ]; then
        EXTRA_ERL_FLAGS="$EXTRA_ERL_FLAGS +Q $ERL_MAX_PORTS"
    fi
    export ERL_FLAGS="${ERL_FLAGS:-} $EXTRA_ERL_FLAGS"
    
    info "Starting worker with node name: $RELEASE_NODE"
    info "ERL_FLAGS: $ERL_FLAGS"
    
    # Start the release
    exec /app/bin/worker start
}

# Cleanup function for graceful shutdown
cleanup() {
    log "Received shutdown signal, cleaning up..."
    
    # Stop the worker gracefully if it's running
    if [ -n "$WORKER_PID" ]; then
        log "Stopping worker process..."
        kill -TERM "$WORKER_PID" 2>/dev/null || true
        
        # Wait for graceful shutdown
        local timeout=30
        local elapsed=0
        while [ $elapsed -lt $timeout ] && kill -0 "$WORKER_PID" 2>/dev/null; do
            sleep 1
            elapsed=$((elapsed + 1))
        done
        
        # Force kill if still running
        if kill -0 "$WORKER_PID" 2>/dev/null; then
            warn "Force killing worker process"
            kill -KILL "$WORKER_PID" 2>/dev/null || true
        fi
    fi
    
    # Stop EPMD if we started it
    if pgrep -f epmd >/dev/null 2>&1; then
        log "Stopping EPMD daemon..."
        pkill -f epmd || true
    fi
    
    log "Cleanup completed"
    exit 0
}

# Signal handlers
trap cleanup TERM INT QUIT

# Pre-flight checks
preflight_checks() {
    log "Running pre-flight checks..."
    
    # Check if running as correct user
    if [ "$(id -u)" -eq 0 ]; then
        warn "Running as root - this is not recommended for production"
    fi
    
    # Check available memory
    if command -v free >/dev/null 2>&1; then
        local mem_available=$(free -m | awk 'NR==2{printf "%.0f", $7}')
        if [ "$mem_available" -lt 100 ]; then
            warn "Low available memory: ${mem_available}MB"
        fi
    fi
    
    # Check disk space
    local disk_usage=$(df /app | awk 'NR==2 {print $5}' | sed 's/%//')
    if [ "$disk_usage" -gt 90 ]; then
        warn "High disk usage: ${disk_usage}%"
    fi
    
    log "Pre-flight checks completed"
}

# Main function
main() {
    log "FLAME Worker Container Initialization"
    log "===================================="
    
    # Run initialization steps
    setup_environment
    preflight_checks
    validate_configuration
    setup_networking
    start_epmd
    
    log "Initialization completed successfully"
    log "Starting FLAME worker..."
    
    # Start the worker (this will exec, so script ends here)
    start_worker
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "FLAME Worker Initialization Script"
        echo ""
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  --help, -h     Show this help message"
        echo "  --version, -v  Show version information"
        echo ""
        echo "Environment Variables:"
        echo "  RELEASE_NODE           Node name (format: name@host)"
        echo "  NODE_NAME              Alternative way to set node name"
        echo "  ERLANG_COOKIE          Erlang cookie for distributed connections"
        echo "  FLAME_DNS_DOMAIN       DNS domain for container networking"
        echo "  ERL_EPMD_ADDRESS       EPMD bind address (default: 0.0.0.0)"
        echo "  ERL_EPMD_PORT          EPMD port (default: 4369)"
        echo "  ERL_MAX_PORTS          Maximum number of Erlang ports"
        echo "  MIX_ENV                Mix environment (default: prod)"
        exit 0
        ;;
    --version|-v)
        echo "FLAME Worker Container v1.0.0"
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac