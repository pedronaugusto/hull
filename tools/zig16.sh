#!/bin/sh
# The Zig the family's ghostty pin builds with (0.16.0), fetched once into
# .tools/ and checked against ziglang.org's release index. hull itself builds
# with Zig 0.17.0; only vt/ (libghostty-vt as a C static library) needs this.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
case "$(uname -m)-$(uname -s)" in
  arm64-Darwin) triple=aarch64-macos ;;
  x86_64-Darwin) triple=x86_64-macos ;;
  x86_64-Linux) triple=x86_64-linux ;;
  aarch64-Linux) triple=aarch64-linux ;;
  *) echo "zig16: no Zig 0.16.0 for $(uname -m)-$(uname -s)" >&2; exit 1 ;;
esac
dir="$here/.tools/zig-$triple-0.16.0"
if [ -x "$dir/zig" ]; then echo "$dir/zig"; exit 0; fi
mkdir -p "$here/.tools"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -sSfL https://ziglang.org/download/index.json -o "$tmp/index.json"
set -- $(python3 -c "import json,sys;e=json.load(open(sys.argv[1]))['0.16.0'][sys.argv[2]];print(e['tarball'],e['shasum'])" "$tmp/index.json" "$triple")
curl -sSfL "$1" -o "$tmp/zig.tar.xz"
echo "$2  $tmp/zig.tar.xz" | shasum -a 256 -c - >&2
tar -C "$here/.tools" -xf "$tmp/zig.tar.xz"
echo "$dir/zig"
