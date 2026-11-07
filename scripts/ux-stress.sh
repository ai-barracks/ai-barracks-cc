#!/usr/bin/env bash
# UX-02: switch to each destination and back while resizing the window to
# its minimum and back, ten rounds per destination, Outputs panel open.
# A SwiftUI inspector inside the NavigationSplitView looped AppKit's
# constraint pass here until the app aborted (2026-11-06). Each run uses a
# copy of the app under a one-off bundle id, so a crash leaves no restore
# prompt behind for the next launch. Exit 0 only if every destination
# finished all rounds.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/dist/AIBCC-PoC.app"
DESTINATIONS="${*:-barrack sessions history rules wiki skills council git}"
[[ -x "$SRC/Contents/MacOS/AIBCCPoC" ]] || { echo "missing $SRC (run scripts/package-app.sh)" >&2; exit 2; }
caffeinate -u -d -t 1800 &
CAF=$!
trap 'kill $CAF 2>/dev/null' EXIT

failed=0
for destination in $DESTINATIONS; do
  id="com.aibarracks.commandcenter.swiftpoc.ux$RANDOM$RANDOM"
  work=$(mktemp -d /tmp/aibcc-ux.XXXXXX)
  cp -R "$SRC" "$work/AIBCC-UX.app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id" "$work/AIBCC-UX.app/Contents/Info.plist"
  codesign --force --deep --sign - "$work/AIBCC-UX.app" >/dev/null 2>&1
  env AIBCC_UX_STRESS="$destination" "$work/AIBCC-UX.app/Contents/MacOS/AIBCCPoC" --selftest-only=ux > "$work/out.txt" 2>&1 &
  app=$!
  for _ in $(seq 1 90); do kill -0 "$app" 2>/dev/null || break; sleep 2; done
  if kill -0 "$app" 2>/dev/null; then
    kill "$app"; status="timeout"
  else
    wait "$app"; status="exit $?"
  fi
  # Done marker (printed after the last round's resize, Codex build-84 F4),
  # no exception, and a normal end: 3 = incomplete run, the usual exit of a
  # partial self-test; 0 would mean every criterion passed.
  if grep -q "stress $destination done" "$work/out.txt" && ! grep -q "Terminating app" "$work/out.txt" \
      && { [ "$status" = "exit 3" ] || [ "$status" = "exit 0" ]; }; then
    echo "PASS $destination ($status)"
  else
    echo "FAIL $destination ($status) $(grep -m1 'reason:' "$work/out.txt" | cut -c1-140)"
    failed=1
  fi
  defaults delete "$id" >/dev/null 2>&1
  rm -rf "$work"
done
exit $failed
