#!/bin/zsh
# Builds "MS-100BT Manager.app" (GUI + the ms100bt engine as a helper) and a headless
# "ms100bt-cli.app" wrapper used to run the engine from a terminal. Both declare the
# Bluetooth usage description that macOS requires; without it the process is killed.
set -e
cd "$(dirname "$0")/.."
# UNIVERSAL=1 builds arm64 + x86_64 and merges them with lipo (used for GitHub releases).
CONFIG=${CONFIG:-release}
VERSION=${VERSION:-0.2.0}
mkdir -p build
if [[ "$UNIVERSAL" == 1 ]]; then
  for arch in arm64 x86_64; do
    swift build -c "$CONFIG" --triple $arch-apple-macosx13.0 --scratch-path .build-$arch
  done
  BIN=build/universal
  mkdir -p "$BIN"
  for exe in MS100BTManager ms100bt; do
    lipo -create .build-arm64/$CONFIG/$exe .build-x86_64/$CONFIG/$exe -output "$BIN/$exe"
  done
else
  swift build -c "$CONFIG"
  BIN=$(swift build -c "$CONFIG" --show-bin-path)
fi

plist() { # $1 = bundle id, $2 = name, $3 = executable, $4 = extra keys
cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$1</string>
  <key>CFBundleName</key><string>$2</string>
  <key>CFBundleDisplayName</key><string>$2</string>
  <key>CFBundleExecutable</key><string>$3</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Connects to the ZOOM MS-100BT pedal to read and install effects.</string>
  $4
</dict></plist>
PLIST
}

APP="build/MS-100BT Manager.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MS100BTManager" "$APP/Contents/MacOS/MS100BTManager"
cp "$BIN/ms100bt" "$APP/Contents/MacOS/ms100bt"
plist io.github.ms100bt.manager "MS-100BT Manager" MS100BTManager "<key>NSHighResolutionCapable</key><true/>" > "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

CLI="build/ms100bt-cli.app"
rm -rf "$CLI"; mkdir -p "$CLI/Contents/MacOS"
cp "$BIN/ms100bt" "$CLI/Contents/MacOS/ms100bt"
plist io.github.ms100bt.cli "ms100bt" ms100bt "<key>LSBackgroundOnly</key><true/>" > "$CLI/Contents/Info.plist"
codesign --force --sign - "$CLI"
echo "Built: $APP and $CLI"
