#!/bin/zsh
# Compila MS100BTProbe.app (arm64) con la descripción de uso de Bluetooth que exige macOS.
set -e
cd "$(dirname "$0")"
APP=build/MS100BTProbe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.lopezchau.ms100bt-probe</string>
  <key>CFBundleName</key><string>MS100BTProbe</string>
  <key>CFBundleExecutable</key><string>MS100BTProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSBackgroundOnly</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Conectarse al pedal ZOOM MS-100BT para leer su identificación.</string>
</dict></plist>
PLIST
swiftc -O -framework IOBluetooth -o "$APP/Contents/MacOS/MS100BTProbe" Sources/main.swift
codesign --force --sign - "$APP"
echo "OK: $APP"
