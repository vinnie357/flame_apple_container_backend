#!/bin/bash
set -e

echo "=== Debug Script Starting ==="
echo "HOME: ${HOME}"
echo "NODE_NAME: ${NODE_NAME}"
echo "ERLANG_COOKIE: ${ERLANG_COOKIE}"
echo "PATH: ${PATH}"
echo "PWD: $(pwd)"

echo "=== Checking Elixir ==="
which elixir
elixir --version

echo "=== Checking EPMD ==="
which epmd
epmd -daemon
sleep 1
epmd -names

echo "=== Testing Mix ==="
cd /app
mix --version

echo "=== Network Configuration ==="
hostname
hostname -i
ip addr show

echo "=== Testing EPMD with verbose output ==="
epmd -d -daemon &
EPMD_PID=$!
sleep 3
echo "EPMD PID: ${EPMD_PID}"
epmd -names || echo "EPMD names failed"
kill ${EPMD_PID} 2>/dev/null || true

echo "=== Testing Simple Elixir Node ==="
timeout 10s elixir --name "test@test.test.local" --cookie "test_cookie" -e "IO.puts(Node.self()); Process.sleep(5000)" || echo "Elixir node test completed"

echo "=== Debug Script Complete ==="