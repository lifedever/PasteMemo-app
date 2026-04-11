#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="PasteMemo"
WATCH_PATHS=(
  "$ROOT_DIR/Sources"
  "$ROOT_DIR/Tests"
  "$ROOT_DIR/Package.swift"
)

SWIFT_RUN_PID=""
DEBOUNCE_PID=""

cleanup() {
  [[ -n "${DEBOUNCE_PID:-}" ]] && kill "$DEBOUNCE_PID" 2>/dev/null || true
  if [[ -n "${SWIFT_RUN_PID:-}" ]] && kill -0 "$SWIFT_RUN_PID" 2>/dev/null; then
    kill "$SWIFT_RUN_PID" 2>/dev/null || true
    wait "$SWIFT_RUN_PID" 2>/dev/null || true
  fi
}

restart_app() {
  printf '\n[%s] restarting %s\n' "$(date '+%H:%M:%S')" "$APP_NAME"
  if [[ -n "${SWIFT_RUN_PID:-}" ]] && kill -0 "$SWIFT_RUN_PID" 2>/dev/null; then
    kill "$SWIFT_RUN_PID" 2>/dev/null || true
    wait "$SWIFT_RUN_PID" 2>/dev/null || true
  fi

  (
    cd "$ROOT_DIR"
    exec env PASTEMEMO_DEV=1 swift run
  ) &
  SWIFT_RUN_PID=$!
}

schedule_restart() {
  # Debounce: cancel previous pending restart, wait 0.5s before restarting
  [[ -n "${DEBOUNCE_PID:-}" ]] && kill "$DEBOUNCE_PID" 2>/dev/null || true
  ( sleep 0.5 && restart_app ) &
  DEBOUNCE_PID=$!
}

poll_signature() {
  find "$ROOT_DIR/Sources" "$ROOT_DIR/Tests" -type f \( -name '*.swift' -o -name '*.strings' -o -name '*.plist' \) -print0 2>/dev/null \
    | xargs -0 stat -f '%N %m' 2>/dev/null
  stat -f '%N %m' "$ROOT_DIR/Package.swift" 2>/dev/null || true
}

watch_with_fswatch() {
  printf '[dev] using fswatch\n'
  fswatch -0 -r --event Updated --event Created --event Removed --event Renamed "${WATCH_PATHS[@]}" | while IFS= read -r -d '' _; do
    schedule_restart
  done
}

watch_with_polling() {
  printf '[dev] fswatch not found, using polling\n'
  local previous current
  previous="$(poll_signature)"
  while true; do
    sleep 1
    current="$(poll_signature)"
    if [[ "$current" != "$previous" ]]; then
      previous="$current"
      restart_app
    fi
  done
}

trap 'cleanup; exit 0' INT TERM EXIT

restart_app

if command -v fswatch >/dev/null 2>&1; then
  watch_with_fswatch
else
  watch_with_polling
fi
