#!/bin/zsh
# Builds the universal app and zips it for a GitHub release: dist/MS-100BT-Manager-<version>-macOS.zip
set -e
cd "$(dirname "$0")/.."
VERSION=${1:-0.2.0}
UNIVERSAL=1 VERSION=$VERSION scripts/build-app.sh
mkdir -p dist
ZIP="dist/MS-100BT-Manager-$VERSION-macOS.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "build/MS-100BT Manager.app" "$ZIP"
shasum -a 256 "$ZIP"
