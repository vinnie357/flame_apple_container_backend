#!/bin/bash
set -e

echo "Starting HTTP-based FLAME worker"
echo "FLAME_WORKER_PORT: ${FLAME_WORKER_PORT:-4000}"

cd /app

# Use Mix to start the application
exec mix run --no-halt