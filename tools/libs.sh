#!/bin/sh
# libghostty-vt and raylib as C static libraries and their headers, into $1, built from
# libs/ by Zig 0.16.0 (HULL_VT_ZIG, else tools/zig16.sh's), ReleaseFast.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
zig=${HULL_VT_ZIG:-$("$here/tools/zig16.sh")}
mkdir -p "$1"; out=$(cd "$1" && pwd)
cd "$here/libs"
exec "$zig" build -Doptimize=ReleaseFast --prefix "$out"
