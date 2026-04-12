#!/bin/bash
set -euo pipefail

APP_NAME="NetMonitor"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="/Applications/$APP_NAME.app"

echo "=============================="
echo "  NetMonitor Installer"
echo "=============================="
echo ""

# Check for Xcode CLI tools (swiftc)
if ! command -v swiftc &>/dev/null; then
    echo "Installing Xcode Command Line Tools (needed once)..."
    xcode-select --install
    echo ""
    echo "A dialog should have appeared. Click 'Install', wait for it to finish,"
    echo "then double-click this file again."
    echo ""
    read -n 1 -s -r -p "Press any key to exit..."
    exit 0
fi

echo "[1/4] Compiling for Apple Silicon (arm64)..."
swiftc \
    -O \
    -target arm64-apple-macos12.0 \
    -o "$SCRIPT_DIR/$APP_NAME" \
    "$SCRIPT_DIR/Sources/main.swift"

echo "[2/4] Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mv "$SCRIPT_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/"

echo "[3/4] Adding to Login Items..."
osascript -e "
tell application \"System Events\"
    if not (exists login item \"$APP_NAME\") then
        make login item at end with properties {path:\"/Applications/$APP_NAME.app\", hidden:false}
    end if
end tell
" 2>/dev/null || echo "    (Login Items — add manually in System Settings if needed)"

echo "[4/4] Launching..."
open "$APP_BUNDLE"

echo ""
echo "Done! NetMonitor is in your menu bar."
echo "It will start automatically on login."
echo ""
echo "To uninstall: drag /Applications/NetMonitor.app to Trash"
read -n 1 -s -r -p "Press any key to close..."
