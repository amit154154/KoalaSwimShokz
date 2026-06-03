#!/bin/zsh
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.local.swim-playlist-sync.plist"
APP_DIR="$HOME/Applications/KoalaSwiming Shokz Playlist.app"
OLD_APP_DIR="$HOME/Applications/Swim Playlist.app"

launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$APP_DIR"
rm -rf "$OLD_APP_DIR"

echo "Removed auto prompt."
