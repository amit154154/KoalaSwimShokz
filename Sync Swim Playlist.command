#!/bin/zsh
set -euo pipefail

DIR="${0:A:h}"
APP="$HOME/Applications/KoalaSwiming Shokz Playlist.app"

if [[ -d "$APP" ]]; then
  /usr/bin/open "$APP" --args --project "$DIR" --playlists "$DIR/playlists" --images "$DIR/playlist_images" --analysis "$DIR/playlist_analysis" --device-name "${SWIM_DEVICE_NAME:-SWIM PRO}"
else
  "$DIR/scripts/swim_playlist_gui.sh"
fi
