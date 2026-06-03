#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
PLAYLISTS_DIR="${SWIM_PLAYLISTS_DIR:-$PROJECT_DIR/playlists}"
DEVICE_NAME="${SWIM_DEVICE_NAME:-}"
AUTO_MODE="${SWIM_AUTO_MODE:-0}"
LOG_FILE="${SWIM_SYNC_LOG:-$PROJECT_DIR/swim-sync.log}"
LOCK_DIR="/tmp/swim-playlist-sync.lock"
AUDIO_EXTENSIONS=(mp3 m4a wav flac aac wma)

mkdir -p "$PLAYLISTS_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi
trap 'rm -rf "$LOCK_DIR"' EXIT

log() {
  print -r -- "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

dialog() {
  local message="$1"
  osascript -e 'display dialog "'"${message//\"/\\\"}"'" buttons {"OK"} default button "OK" with title "KoalaSwiming Shokz Playlist"' >/dev/null
}

notify() {
  local message="$1"
  osascript -e 'display notification "'"${message//\"/\\\"}"'" with title "KoalaSwiming Shokz Playlist"' >/dev/null
}

choose_from_list() {
  local prompt="$1"
  shift
  osascript - "$@" <<APPLESCRIPT
on run argv
  set picked to choose from list argv with title "KoalaSwiming Shokz Playlist" with prompt "$prompt"
  if picked is false then
    return "__CANCEL__"
  end if
  return item 1 of picked
end run
APPLESCRIPT
}

confirm_sync() {
  local playlist="$1"
  local target="$2"
  local count="$3"
  osascript - "$playlist" "$target" "$count" <<'APPLESCRIPT'
on run argv
  set playlistName to item 1 of argv
  set targetName to item 2 of argv
  set audioCount to item 3 of argv
  set msg to "Sync playlist '" & playlistName & "' to '" & targetName & "'?" & return & return & "This will replace existing audio files on the selected drive, then copy " & audioCount & " audio file(s)."
  set picked to display dialog msg buttons {"Cancel", "Sync"} default button "Sync" cancel button "Cancel" with title "KoalaSwiming Shokz Playlist" with icon caution
  return button returned of picked
end run
APPLESCRIPT
}

is_writable_volume() {
  local volume="$1"
  [[ -d "$volume" && -w "$volume" && "$volume" != "/Volumes" ]]
}

detect_target_volume() {
  local exact="/Volumes/$DEVICE_NAME"
  if [[ -n "$DEVICE_NAME" ]]; then
    if [[ -d "$exact" ]]; then
      print -r -- "$exact"
      return 0
    fi
    return 1
  fi

  local candidates=()
  local volume name upper
  for volume in /Volumes/*(N); do
    is_writable_volume "$volume" || continue
    name="${volume:t}"
    upper="${(U)name}"
    if [[ "$upper" == *SHOKZ* || "$upper" == *OPENSWIM* || "$upper" == *"OPEN SWIM"* || "$upper" == *SWIM* ]]; then
      candidates+=("$volume")
    fi
  done

  if (( ${#candidates} == 1 )); then
    print -r -- "$candidates[1]"
    return 0
  fi

  if (( ${#candidates} > 1 )); then
    local candidate_names=()
    for volume in "${candidates[@]}"; do
      candidate_names+=("${volume:t}")
    done

    local picked_candidate
    picked_candidate="$(choose_from_list "Choose the headphones drive:" "${candidate_names[@]}")"
    [[ "$picked_candidate" != "__CANCEL__" ]] || return 2
    print -r -- "/Volumes/$picked_candidate"
    return 0
  fi

  if [[ "$AUTO_MODE" == "1" ]]; then
    return 1
  fi

  local volumes=()
  for volume in /Volumes/*(N); do
    is_writable_volume "$volume" || continue
    volumes+=("${volume:t}")
  done

  if (( ${#volumes} == 0 )); then
    return 1
  fi

  local picked
  picked="$(choose_from_list "Choose the headphones drive:" "${volumes[@]}")"
  [[ "$picked" != "__CANCEL__" ]] || return 2
  print -r -- "/Volumes/$picked"
}

playlist_dirs=()
for dir in "$PLAYLISTS_DIR"/*(/N); do
  playlist_dirs+=("${dir:t}")
done

if (( ${#playlist_dirs} == 0 )); then
  dialog "No playlist folders found. Add MP3s inside folders under: $PLAYLISTS_DIR"
  exit 1
fi

if ! target_volume="$(detect_target_volume)"; then
  if [[ "$AUTO_MODE" == "1" ]]; then
    log "Auto mode skipped: no Shokz/OpenSwim-looking writable volume."
    exit 0
  fi

  dialog "No writable headphones drive was found. Connect the Shokz, wait for it to appear in Finder, then try again."
  exit 1
fi

selected_playlist="$(choose_from_list "Choose the playlist to sync:" "${playlist_dirs[@]}")"
if [[ "$selected_playlist" == "__CANCEL__" ]]; then
  log "Cancelled before playlist selection."
  exit 0
fi

selected_dir="$PLAYLISTS_DIR/$selected_playlist"
audio_count=0
for ext in "${AUDIO_EXTENSIONS[@]}"; do
  files=( "$selected_dir"/**/*.$ext(N) "$selected_dir"/**/*.${(U)ext}(N) )
  audio_count=$(( audio_count + ${#files} ))
done

if (( audio_count == 0 )); then
  dialog "The selected playlist has no supported audio files: $selected_playlist"
  exit 1
fi

confirm_sync "$selected_playlist" "${target_volume:t}" "$audio_count" >/dev/null

log "Sync started: playlist='$selected_playlist' target='$target_volume' count=$audio_count"

find_args=()
for ext in "${AUDIO_EXTENSIONS[@]}"; do
  find_args+=( -iname "*.$ext" -o )
done
find_args[-1]=()

find "$target_volume" -type f \( "${find_args[@]}" \) -delete

rsync_args=(
  -av
  --prune-empty-dirs
  --exclude='.*'
  --exclude='__MACOSX'
  --include='*/'
)

for ext in "${AUDIO_EXTENSIONS[@]}"; do
  rsync_args+=( --include="*.$ext" --include="*.${(U)ext}" )
done

rsync_args+=( --exclude='*' "$selected_dir"/ "$target_volume"/ )
rsync "${rsync_args[@]}" >> "$LOG_FILE" 2>&1

sync
log "Sync finished: playlist='$selected_playlist' target='$target_volume'"
notify "Finished syncing '$selected_playlist' to '${target_volume:t}'."
