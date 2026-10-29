#!/bin/zsh
# Builds xShot (Release), signs it with a stable identity so the screen-recording
# permission survives rebuilds, and optionally installs it to /Applications.
#   scripts/build.sh            build only -> build/xShot.app
#   scripts/build.sh install    build, copy to /Applications and relaunch
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${XSHOT_SIGN_IDENTITY:-}"

xcodegen generate --quiet
xcodebuild -project xShot.xcodeproj -scheme xShot -configuration Release \
  -derivedDataPath build/DerivedData build -quiet

rm -rf build/xShot.app
cp -R build/DerivedData/Build/Products/Release/xShot.app build/xShot.app
if [[ -n "$IDENTITY" ]]; then
  # Several certificates can share one name, so sign by SHA-1 when available.
  HASH=$(security find-identity -v -p codesigning | grep -F "$IDENTITY" | head -1 | awk '{print $2}')
  codesign --force --deep --sign "${HASH:-$IDENTITY}" build/xShot.app
else
  echo "warning: XSHOT_SIGN_IDENTITY not set, signing ad-hoc (screen-recording permission resets on every rebuild)" >&2
  codesign --force --deep --sign - build/xShot.app
fi
echo "Built build/xShot.app"

if [[ "${1:-}" == "install" ]]; then
  pkill -x xShot 2>/dev/null || true
  rm -rf /Applications/xShot.app
  cp -R build/xShot.app /Applications/xShot.app
  open /Applications/xShot.app
  echo "Installed /Applications/xShot.app"
fi
