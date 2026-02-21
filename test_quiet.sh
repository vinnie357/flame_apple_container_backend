#!/bin/bash
# Quiet test runner that only shows test results
# Usage: ./test_quiet.sh [test arguments]

# Run tests and filter output to show only test results
mix test "$@" 2>/dev/null | grep -E "^\.|^Running|^Finished|^[0-9]+ doctest|^[0-9]+ test|failures|errors|^$" | grep -v "^$"