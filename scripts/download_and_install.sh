#!/usr/bin/env bash
#
# Remote installer for the dockd CLI.
#
# Downloads the dockd repository, builds the Burrito release, and installs the
# `dockd` binary for the host OS. Intended to be run standalone, e.g.:
#
#   curl -fsSL https://raw.githubusercontent.com/cylkdev/dockd/main/scripts/remote_install.sh | bash
#
# Requires: git, and the toolchain the release build needs (elixir/mix).
#
# Environment overrides:
#   DOCKD_REPO    git URL to clone            (default: https://github.com/cylkdev/dockd)
#   DOCKD_REF     branch/tag/commit to build  (default: main)
#   DOCKD_DIR     directory to clone into      (default: a fresh temp dir, removed on exit)
set -euo pipefail

REPO="${DOCKD_REPO:-https://github.com/cylkdev/dockd}"
REF="${DOCKD_REF:-main}"

command -v git >/dev/null 2>&1 || { echo "error: git is required but not installed." >&2; exit 1; }

# Choose a clone directory. When DOCKD_DIR is unset we use a temp dir and clean
# it up on exit; when the caller supplies one we leave it in place.
cleanup=""
if [ -n "${DOCKD_DIR:-}" ]; then
  clone_dir="$DOCKD_DIR"
else
  clone_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockd-install.XXXXXX")"
  cleanup="$clone_dir"
fi
trap '[ -n "$cleanup" ] && rm -rf "$cleanup"' EXIT

echo "==> Cloning $REPO (ref: $REF)"
git clone --depth 1 --branch "$REF" "$REPO" "$clone_dir"

cd "$clone_dir"

echo "==> Building release"
scripts/build_release.sh

echo "==> Installing release"
scripts/install.sh

echo "==> dockd installation complete."
