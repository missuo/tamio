#!/bin/bash
# Node keeps asset stamping identical on macOS, Linux, and in CI.
set -euo pipefail
node "$(dirname "$0")/scripts/stamp.mjs" "$@"
