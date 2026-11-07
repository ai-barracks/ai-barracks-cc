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

# verdict <destination> <status> <stdout file> <report dir>: PASS needs the
# done marker (printed after the last round's resize), no exception, a
# normal end (3 = incomplete run, the usual exit of a partial self-test;
# 0 = every criterion passed) and the run's own report saying UX-02 pass
# (Codex build-84 F4). Kept separate so --check-verdict can test it.
verdict() {
  local destination=$1 status=$2 out=$3 reports=$4 report
  report=$(ls -t "$reports"/*/report.json 2>/dev/null | head -1)
  grep -q "stress $destination done" "$out" || { echo "no done marker"; return 1; }
  ! grep -q "Terminating app" "$out" || { echo "exception"; return 1; }
  [ "$status" = "exit 3" ] || [ "$status" = "exit 0" ] || { echo "status $status"; return 1; }
  [ -n "$report" ] || { echo "no report"; return 1; }
  python3 - "$report" <<'PY2' || { echo "UX-02 not pass in report"; return 1; }
import json, sys
results = json.load(open(sys.argv[1]))["results"]
sys.exit(0 if any(r["id"] == "UX-02" and r["status"] == "pass" for r in results) else 1)
PY2
}

# --check-verdict: run the verdict on synthetic runs (no app launched).
if [[ "${1:-}" == "--check-verdict" ]]; then
  t=$(mktemp -d /tmp/aibcc-uxv.XXXXXX)
  mkdir -p "$t/r/a" "$t/r0"
  printf 'stress git round 9\nstress git done\n' > "$t/ok.txt"
  printf 'stress git round 9\n' > "$t/hang.txt"
  printf 'stress git done\n*** Terminating app\n' > "$t/crash.txt"
  echo '{"results":[{"id":"UX-02","status":"pass"}]}' > "$t/r/a/report.json"
  mkdir -p "$t/rf/a"; echo '{"results":[{"id":"UX-02","status":"fail"}]}' > "$t/rf/a/report.json"
  bad=0
  check() { local want=$1; shift; if verdict "$@" >/dev/null; then got=pass; else got=fail; fi
            [ "$got" = "$want" ] && echo "ok   $want: $*" || { echo "BAD  want $want: $*"; bad=1; }; }
  check pass git "exit 3" "$t/ok.txt" "$t/r"
  check pass git "exit 0" "$t/ok.txt" "$t/r"
  check fail git "exit 3" "$t/hang.txt" "$t/r"
  check fail git "exit 3" "$t/crash.txt" "$t/r"
  check fail git "timeout" "$t/ok.txt" "$t/r"
  check fail git "exit 134" "$t/ok.txt" "$t/r"
  check fail git "exit 3" "$t/ok.txt" "$t/r0"
  check fail git "exit 3" "$t/ok.txt" "$t/rf"
  check fail wiki "exit 3" "$t/ok.txt" "$t/r"
  rm -rf "$t"
  exit $bad
fi

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
  env AIBCC_UX_STRESS="$destination" AIBCC_SELFTEST_OUT="$work/reports" \
    "$work/AIBCC-UX.app/Contents/MacOS/AIBCCPoC" --selftest-only=ux > "$work/out.txt" 2>&1 &
  app=$!
  for _ in $(seq 1 90); do kill -0 "$app" 2>/dev/null || break; sleep 2; done
  if kill -0 "$app" 2>/dev/null; then
    kill "$app"; status="timeout"
  else
    wait "$app"; status="exit $?"
  fi
  if why=$(verdict "$destination" "$status" "$work/out.txt" "$work/reports"); then
    echo "PASS $destination ($status)"
  else
    echo "FAIL $destination ($status) $why $(grep -m1 'reason:' "$work/out.txt" | cut -c1-140)"
    failed=1
  fi
  defaults delete "$id" >/dev/null 2>&1
  rm -rf "$work"
done
exit $failed
