#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
PLIST="$HOME/Library/LaunchAgents/com.local.swim-playlist-sync.plist"
APP_NAME="KoalaSwiming Shokz Playlist"
APP_DIR="$HOME/Applications/$APP_NAME.app"
OLD_APP_DIR="$HOME/Applications/Swim Playlist.app"
APP_BIN="$APP_DIR/Contents/MacOS/SwimPlaylistGUI"
ICON_SOURCE="$PROJECT_DIR/assets/app_icon.png"
ICON_FILE="AppIcon.icns"

mkdir -p "$HOME/Library/LaunchAgents"
if [[ -d "$OLD_APP_DIR" && "$OLD_APP_DIR" != "$APP_DIR" ]]; then
  rm -rf "$OLD_APP_DIR"
fi
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$PROJECT_DIR/.swift-module-cache"

/usr/bin/swiftc \
  -module-cache-path "$PROJECT_DIR/.swift-module-cache" \
  "$PROJECT_DIR/scripts/SwimPlaylistGUI.swift" \
  -o "$APP_BIN"

if [[ -f "$ICON_SOURCE" ]]; then
  ICONSET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/koala-iconset.XXXXXX")"
  trap 'rm -rf "$ICONSET_DIR"' EXIT
  mkdir -p "$ICONSET_DIR/AppIcon.iconset"

  /usr/bin/sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_16x16.png" >/dev/null
  /usr/bin/sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_16x16@2x.png" >/dev/null
  /usr/bin/sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_32x32.png" >/dev/null
  /usr/bin/sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_32x32@2x.png" >/dev/null
  /usr/bin/sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_128x128.png" >/dev/null
  /usr/bin/sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_128x128@2x.png" >/dev/null
  /usr/bin/sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_256x256.png" >/dev/null
  /usr/bin/sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_256x256@2x.png" >/dev/null
  /usr/bin/sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_512x512.png" >/dev/null
  /usr/bin/sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_512x512@2x.png" >/dev/null
  /usr/bin/iconutil -c icns "$ICONSET_DIR/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/$ICON_FILE"
  cp "$ICON_SOURCE" "$APP_DIR/Contents/Resources/app_icon.png"
  chmod 644 "$APP_DIR/Contents/Resources/$ICON_FILE" "$APP_DIR/Contents/Resources/app_icon.png"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>SwimPlaylistGUI</string>
  <key>CFBundleIdentifier</key>
  <string>com.local.koalaswiming-shokz-playlist</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>$ICON_FILE</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
</dict>
</plist>
PLIST

touch "$APP_DIR"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.local.swim-playlist-sync</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>$APP_DIR</string>
    <string>--args</string>
    <string>--project</string>
    <string>$PROJECT_DIR</string>
    <string>--playlists</string>
    <string>$PROJECT_DIR/playlists</string>
    <string>--images</string>
    <string>$PROJECT_DIR/playlist_images</string>
    <string>--analysis</string>
    <string>$PROJECT_DIR/playlist_analysis</string>
    <string>--device-name</string>
    <string>SWIM PRO</string>
    <string>--auto</string>
  </array>
  <key>WatchPaths</key>
  <array>
    <string>/Volumes</string>
  </array>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>$PROJECT_DIR/swim-sync.launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$PROJECT_DIR/swim-sync.launchd.err.log</string>
</dict>
</plist>
PLIST

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "Installed auto prompt."
echo "Installed app: $APP_DIR"
echo "It will run when /Volumes changes, such as when the Shokz drive mounts."

if [[ "${1:-}" == "--open-now" ]]; then
  /usr/bin/open "$APP_DIR" --args --project "$PROJECT_DIR" --playlists "$PROJECT_DIR/playlists" --images "$PROJECT_DIR/playlist_images" --analysis "$PROJECT_DIR/playlist_analysis" --device-name "SWIM PRO"
  echo "Opened the playlist GUI for the currently connected device."
fi
