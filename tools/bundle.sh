#!/bin/sh
# An app's .app: tools/bundle.sh <hull> <app-dir> <out-dir>
#
# The bundle is the app's, never hull's: its name, identifier, version and
# icon come from the app's hull.zon. hull is the executable, renamed to the
# app's name so the process, the Dock and the menus say it; the program
# rides in Contents/Resources/program, and hull.zon in Contents/Resources.
# Unsigned beyond the linker's ad-hoc signature (a spike).
set -eu
hull=$1
app=$(cd "$2" && pwd)
mkdir -p "$3"
out=$(cd "$3" && pwd)
eval "$("$hull" --app "$app" --describe)"
: "${NAME:?}" "${ID:?}" "${VERSION:?}" "${PROGRAM:?}" "${PROGRAM_SOURCE:?no program_source in hull.zon}"
bundle="$out/$NAME.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/program"
cp "$hull" "$bundle/Contents/MacOS/$NAME"
cp "$PROGRAM_SOURCE" "$bundle/Contents/Resources/program/$PROGRAM"
cp "$app/hull.zon" "$bundle/Contents/Resources/hull.zon"

icon_key=""
if [ -n "${ICON:-}" ] && command -v iconutil >/dev/null 2>&1; then
  set_dir=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$set_dir"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON" --out "$set_dir/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$ICON" --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$set_dir" -o "$bundle/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$set_dir")"
  icon_key="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  $icon_key
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
</dict>
</plist>
EOF
# ad-hoc, so Apple silicon runs what was copied and the bundle is sealed
codesign --force --sign - "$bundle/Contents/Resources/program/$PROGRAM" >/dev/null 2>&1 || true
codesign --force --sign - "$bundle" >/dev/null 2>&1 || true
echo "$bundle"
