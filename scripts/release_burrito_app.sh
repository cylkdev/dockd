#!/usr/bin/env bash
#
# Build the dockd CLI as a production release.
#
# Assembles the `dockd` release (defined in the umbrella mix.exs) under
# MIX_ENV=prod and wraps it into standalone binaries via Burrito. The wrapped
# binaries land in ./burrito_out/ (one per Burrito target: macos, linux).
#
# Usage: scripts/release_burrito_app.sh
set -euo pipefail

# Run from the umbrella root regardless of where the script is invoked.
cd "$(dirname "$0")/.."

export MIX_ENV=prod

echo "==> Fetching prod dependencies"
mix deps.get --only prod

echo "==> Compiling application (MIX_ENV=prod)"
mix compile

echo "==> Building Burrito release 'dockd'"
mix release dockd --overwrite

echo "==> Done. Release exported to ./burrito_out/"
