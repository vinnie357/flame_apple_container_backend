#!/bin/sh
# Optional worker init wrapper for FLAME containers.
#
# In most cases you do NOT need this script. The Elixir release entrypoint
# handles RELEASE_NODE, RELEASE_COOKIE, and RELEASE_DISTRIBUTION automatically.
# The backend sets all required env vars before starting the container.
#
# Use this script only if you need custom pre-boot steps (e.g. fetching
# secrets, waiting for a dependency, configuring volumes).
#
# Usage in Dockerfile:
#   ENTRYPOINT ["/app/bin/worker-init.sh"]
#   CMD ["start"]

set -e

log() { echo "[worker-init] $1"; }

# --- Add custom pre-boot steps here ---
# Example: wait for a database
# log "Waiting for database..."
# until nc -z "$DB_HOST" 5432 2>/dev/null; do sleep 1; done

# Verify FLAME_PARENT is set (required for FLAME.Terminator to connect back)
if [ -z "$FLAME_PARENT" ]; then
  log "WARNING: FLAME_PARENT not set. This container was not started by a FLAME backend."
fi

# Hand off to the release entrypoint
exec /app/bin/flame_worker "$@"
