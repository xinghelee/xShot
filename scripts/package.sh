#!/bin/zsh
# Packages build/xShot.app into dist/xShot-<version>.dmg and .zip.
#   scripts/package.sh <version>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/package.sh <version>}"
APP=build/xShot.app
[[ -d "$APP" ]] || { echo "error: $APP not found, run scripts/build.sh first" >&2; exit 1; }

rm -rf dist
mkdir -p dist
ditto -c -k --keepParent "$APP" "dist/xShot-$VERSION.zip"

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp -R "$APP" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname xShot -srcfolder "$staging" -format UDZO -ov "dist/xShot-$VERSION.dmg"

ls -lh dist
