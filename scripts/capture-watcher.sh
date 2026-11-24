#!/usr/bin/env bash
# Serves window-capture requests from `--selftest` (RS-01b). Run it in a
# separate terminal *before* the self-test; it needs a process that already
# has screen-capture permission. Captures are composited window images, so
# they show what is really on screen (unlike Metal-less view snapshots).
set -euo pipefail

BASE="${AIBCC_SELFTEST_OUT:-$HOME/Library/Application Support/AIBCCPoC/selftest}"
DURATION_SECONDS="${DURATION_SECONDS:-900}"
POLL_SECONDS="${POLL_SECONDS:-0.2}"
# The app waits 4 s for a capture; an older request is stale (its window may
# be gone) and retrying it only delays the live ones.
MAX_REQUEST_AGE_SECONDS="${MAX_REQUEST_AGE_SECONDS:-10}"

request_age() {
  echo $(( $(date +%s) - $(stat -f %m "$1") ))
}

serve_request() {
  local request="$1" window output
  (( $(request_age "$request") <= MAX_REQUEST_AGE_SECONDS )) || return 0
  window="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["window"])' "$request")"
  output="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["output"])' "$request")"
  if [[ ! -e "$output" ]]; then
    # A request can arrive before the window is composited; a failure must
    # not end the watcher (set -e), the next poll retries.
    if screencapture -x -o -l "$window" "$output" 2>/dev/null; then
      echo "captured: $output"
    else
      echo "retry: window $window not capturable yet ($output)"
    fi
  fi
}

main() {
  local end=$((SECONDS + DURATION_SECONDS)) request started
  mkdir -p "$BASE"
  # Requests left by earlier runs are never served.
  started="$(mktemp)"
  trap 'rm -f "'"$started"'"' EXIT
  echo "watching $BASE for ${DURATION_SECONDS}s"
  while (( SECONDS < end )); do
    while IFS= read -r -d '' request; do
      serve_request "$request"
    done < <(find "$BASE" -name 'capture-request-*.json' -newer "$started" -print0 2>/dev/null)
    sleep "$POLL_SECONDS"
  done
}

main "$@"
