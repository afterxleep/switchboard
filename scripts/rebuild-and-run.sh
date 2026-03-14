#!/bin/bash
set -e

REPO_URL="https://github.com/afterxleep/switchboard"
BUILD_DIR="$HOME/Developer/switchboard-build"
BINARY_PATH="$HOME/bin/switchboard"
LAUNCH_AGENT_LABEL="com.switchboard.daemon"

echo "==> Pulling latest from $REPO_URL"
if [ -d "$BUILD_DIR" ]; then
    cd "$BUILD_DIR" && git pull origin main
else
    git clone "$REPO_URL" "$BUILD_DIR" && cd "$BUILD_DIR"
fi

echo "==> Building release"
cd "$BUILD_DIR"
swift build -c release

echo "==> Installing binary"
mkdir -p "$(dirname "$BINARY_PATH")"
cp .build/release/flowdeck-daemon "$BINARY_PATH"
chmod +x "$BINARY_PATH"

echo "==> Restarting daemon"
launchctl kickstart -k "gui/$(id -u)/$LAUNCH_AGENT_LABEL" 2>/dev/null || \
    launchctl load "$HOME/Library/LaunchAgents/com.switchboard.daemon.plist" 2>/dev/null || \
    echo "Note: launchd service not found — run the daemon manually with: $BINARY_PATH"

echo "==> Done. Binary at $BINARY_PATH"
