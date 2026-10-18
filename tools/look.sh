#!/bin/sh
# One of WAKE's screens as hull draws it, headless, into shots/:
#   tools/look.sh [title|hide-and-seek] [out.png]
# The same renderer as the window, on the CPU; no display needed.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
screen=${1:-hide-and-seek}
out=${2:-$here/shots/$screen.png}
case "$screen" in
  title) keys=""; at=3 ;;
  hide-and-seek) keys="--keys 1.5:enter,3.5:enter"; at=6.5 ;;
  *) echo "look: title or hide-and-seek" >&2; exit 1 ;;
esac
# shellcheck disable=SC2086
"$here/zig-out/bin/hull" --app "$here/apps/wake" --headless "$out" --at $at $keys
