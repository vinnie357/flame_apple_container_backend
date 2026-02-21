#!/bin/bash
# Test script to verify LiveView tests are working with Floki

echo "Running LiveView tests with Floki..."
MIX_ENV=test mix test test/flame_web/live/dashboard_live_test.exs --no-start

echo "Exit code: $?"