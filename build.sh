#!/bin/bash
set -euo pipefail

# Manual build script (alternative to Install NetMonitor.command)
# For M1/M2/M3 Macs. For Intel: change arm64 to x86_64

APP_NAME="NetMonitor"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."

swiftc -O -target arm64-apple-macos12.0 \
    -o "$BUILD_DIR/$APP_NAME" \
    "$BUILD_DIR/Sources/main.swift"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mv "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$BUILD_DIR/Info.plist" "$APP_BUNDLE/Contents/"

echo "Done: $APP_BUNDLE"
echo "Run:  open $APP_BUNDLE"
echo "Install: cp -r $APP_BUNDLE /Applications/"
