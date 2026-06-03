#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
LOCK_DIR="/tmp/swim-playlist-gui.lock"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi
trap 'rm -rf "$LOCK_DIR"' EXIT

sleep 1

export SWIM_PROJECT_DIR="${SWIM_PROJECT_DIR:-$PROJECT_DIR}"
mkdir -p "$PROJECT_DIR/.swift-module-cache"
/usr/bin/swift -module-cache-path "$PROJECT_DIR/.swift-module-cache" "$SCRIPT_DIR/SwimPlaylistGUI.swift"
