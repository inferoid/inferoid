#!/bin/bash
# Builds "Inferoid Notes.app" (release) and signs it ad hoc for running on this Mac.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | grep -v "^.*Compiling" || true
BIN=$(swift build -c release --show-bin-path)
APP="build/Inferoid Notes.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/InferoidNotes" "$APP/Contents/MacOS/"
find "$BIN" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;
cp Info.plist "$APP/Contents/"
if [ -f Resources/AppIcon-1024.png ]; then  # Inferoid logo -> AppIcon.icns (macOS sips + iconutil)
  SET=build/AppIcon.iconset; rm -rf "$SET"; mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/AppIcon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --deep --sign - "$APP"
echo "built $APP"
