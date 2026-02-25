#!/bin/sh
# Health check for FLAME worker containers.
#
# Checks that the BEAM process is running. The FLAME.Terminator handles
# its own connection monitoring — if it loses contact with the parent,
# it shuts down the system automatically.
#
# Usage in Dockerfile:
#   HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
#     CMD /app/bin/health-check.sh

set -e

# Check BEAM process is alive
pgrep -f beam.smp >/dev/null 2>&1 || {
  echo "BEAM process not running"
  exit 1
}

# Check EPMD is responding (distributed Erlang is functional)
epmd -names >/dev/null 2>&1 || {
  echo "EPMD not responding"
  exit 1
}
