#!/usr/bin/env bash
# Serves window-capture requests from `--selftest` (RS-01b). Run it in a
# separate terminal *before* the self-test; it needs a process that already
# has screen-capture permission. Captures are composited window images, so
# they show what is really on screen (unlike Metal-less view snapshots).
set -euo pipefail

BASE="${AIBCC_SELFTEST_OUT:-$HOME/Library/Application Support/AIBCCPoC/selftest}"
DURATION_SECONDS="${DURATION_SECONDS:-900}"
POLL_SECONDS="${POLL_SECONDS:-0.2}"

serve_request() {
  local request="$1" window output
  window="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["window"])' "$request")"
  output="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["output"])' "$request")"
  if [[ ! -e "$output" ]]; then
    screencapture -x -o -l "$window" "$output" && echo "captured: $output"
  fi
}

main() {
  local end=$((SECONDS + DURATION_SECONDS)) request
  mkdir -p "$BASE"
  echo "watching $BASE for ${DURATION_SECONDS}s"
  while (( SECONDS < end )); do
    while IFS= read -r -d '' request; do
      serve_request "$request"
    done < <(find "$BASE" -name 'capture-request-*.json' -print0 2>/dev/null)
    sleep "$POLL_SECONDS"
  done
}

main "$@"
