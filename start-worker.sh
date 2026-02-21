#!/bin/bash
set -e

echo "Starting FLAME worker with NODE_NAME=${NODE_NAME} and COOKIE=${ERLANG_COOKIE}"

# Get container IP address
CONTAINER_IP=$(hostname -i | awk '{print $1}')
echo "Container IP: ${CONTAINER_IP}"
echo "Container hostname: $(hostname)"

# Kill any existing EPMD process
pkill -f epmd || true
sleep 1

# Start EPMD daemon first with proper configuration
echo "Starting EPMD daemon..."
epmd -daemon -address 0.0.0.0 -port 4369 -relaxed_command_check

# Wait for EPMD to be ready with better checking
echo "Waiting for EPMD to be ready..."
for i in {1..10}; do
    if epmd -names > /dev/null 2>&1; then
        echo "EPMD is ready"
        break
    fi
    echo "EPMD not ready yet, waiting... ($i/10)"
    sleep 2
done

# Verify EPMD is working
epmd -names || echo "EPMD check failed"

# Create a basic sys.config for distribution
cat > /tmp/sys.config << 'EOF'
[
  {kernel, [
    {inet_dist_listen_min, 9001},
    {inet_dist_listen_max, 9999},
    {inet_dist_use_interface, {0,0,0,0}}
  ]}
].
EOF

echo "Starting Erlang node..."
cd /app

# Use short name instead of long name to avoid EPMD issues
SHORT_NAME=${NODE_NAME%%@*}
echo "Using short name: ${SHORT_NAME:-worker}"

exec erl -sname "${SHORT_NAME:-worker}" \
         -setcookie "${ERLANG_COOKIE:-flame_cookie}" \
         -config /tmp/sys \
         -kernel inet_dist_listen_min 9001 \
         -kernel inet_dist_listen_max 9999 \
         -kernel inet_dist_use_interface '{0,0,0,0}' \
         -pa "_build/dev/lib/*/ebin" \
         -noshell \
         -eval "
           io:format(\"Starting node with name: ~p~n\", [node()]),
           timer:sleep(2000),
           io:format(\"Node started: ~p~n\", [node()]),
           io:format(\"Cookie: ~p~n\", [erlang:get_cookie()]),
           case application:ensure_all_started(flame) of
             {ok, _} -> io:format(\"FLAME started successfully~n\");
             Error -> io:format(\"FLAME start error: ~p~n\", [Error])
           end,
           io:format(\"Worker ready and waiting...~n\"),
           receive stop -> ok end
         "