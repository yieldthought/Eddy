#!/bin/bash
# Builds Eddy.app into ./build.
#   --icon     redraw the app icon
#   --install  also copy the app to /Applications (quit Eddy first)
set -euo pipefail
cd "$(dirname "$0")"

icon=false
install=false
for arg in "$@"; do
  case "$arg" in
    --icon) icon=true ;;
    --install) install=true ;;
    *) echo "unknown option: $arg" >&2; exit 64 ;;
  esac
done

if $icon || [[ ! -f Resources/AppIcon.icns ]]; then
  tmp="$(mktemp -d)"
  swiftc -O Tools/make-icon.swift -o "$tmp/make-icon"
  "$tmp/make-icon" "$tmp/AppIcon.iconset"
  iconutil -c icns "$tmp/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$tmp"
fi

swift build -c release
app="build/Eddy.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Eddy" "$app/Contents/MacOS/Eddy"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app" >/dev/null
echo "Built $(pwd)/$app"

if $install; then
  if pgrep -xq Eddy; then
    echo "Eddy is running; quit it first, then run ./build.sh --install again." >&2
    exit 1
  fi
  target="/Applications/Eddy.app"
  rm -rf "$target"
  ditto "$app" "$target"
  lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
  "$lsregister" -u "$(pwd)/$app" 2>/dev/null || true
  "$lsregister" -f "$target"
  echo "Installed $target"
fi
