#!/usr/bin/env bash
# Builds "build/Task Tracker.app" and the `menu` command. Pass --install to copy the app to
# /Applications and launch it, and the command to ~/.local/bin/menu.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Task Tracker"
EXECUTABLE="TaskTracker"
BUNDLE_ID="local.TaskTracker"
VERSION="1.0"

swift build -c release --product "$EXECUTABLE"
swift build -c release --product menu
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Task Tracker opens Claude Code in Ghostty to fix the problems you report on the menu.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x "$EXECUTABLE" || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    open "/Applications/$APP_NAME.app"
    echo "Installed and launched /Applications/$APP_NAME.app"
    mkdir -p "$HOME/.local/bin"
    cp "$BIN_DIR/menu" "$HOME/.local/bin/menu"
    echo "Installed $HOME/.local/bin/menu"
fi
