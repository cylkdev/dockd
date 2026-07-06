#!/usr/bin/env bash
#
# Install the dockd CLI built by scripts/release_burrito_app.sh.
#
# Detects the host OS, picks the matching Burrito binary from ./burrito_out/
# (dockd_macos on Darwin, dockd_linux on Linux), and installs it as `dockd`
# into a bin directory on PATH.
#
# Usage: scripts/install_burrito_release.sh [install_dir]
#   install_dir defaults to /usr/local/bin (falls back to ~/.local/bin when
#   that is not writable). Override DESTDIR by passing it as the first arg.
set -euo pipefail

# Run from the umbrella root regardless of where the script is invoked.
cd "$(dirname "$0")/.."

# Map the host OS to the Burrito target name used in mix.exs.
case "$(uname -s)" in
  Darwin) target="macos" ;;
  Linux)  target="linux" ;;
  *)
    echo "error: unsupported OS '$(uname -s)' (dockd releases target macOS and Linux only)" >&2
    exit 1
    ;;
esac

binary="burrito_out/dockd_${target}"

if [ ! -f "$binary" ]; then
  echo "error: release binary '$binary' not found." >&2
  echo "       Build it first with: scripts/release_burrito_app.sh" >&2
  exit 1
fi

# Resolve the install directory: explicit arg, else /usr/local/bin, else ~/.local/bin.
if [ "$#" -ge 1 ]; then
  install_dir="$1"
elif [ -w /usr/local/bin ] || { [ ! -e /usr/local/bin ] && [ -w /usr/local ]; }; then
  install_dir="/usr/local/bin"
else
  install_dir="$HOME/.local/bin"
fi

mkdir -p "$install_dir"

dest="$install_dir/dockd"
echo "==> Installing $binary -> $dest"
install -m 0755 "$binary" "$dest"

echo "==> Installed dockd ($target) to $dest"
case ":$PATH:" in
  *":$install_dir:"*) ;;
  *) echo "note: $install_dir is not on your PATH; add it to use 'dockd' directly." >&2 ;;
esac
