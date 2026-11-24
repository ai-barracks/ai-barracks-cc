#!/usr/bin/env bash
# PK-01 (known issue #1): run the packaged app with the build-path resource
# bundle moved aside. SwiftPM's generated Bundle.module falls back to that
# absolute path and fatalErrors without it, so any lookup that still goes
# through it crashes the app here. The bundle is always moved back.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-debug}"
APP="$ROOT/dist/AIBCC-PoC.app"
OUT_BASE="$HOME/Library/Application Support/AIBCCPoC/selftest"
BUILD_BUNDLE="$ROOT/.build/arm64-apple-macosx/$CONFIG/GhosttyKit_GhosttyTerminal.bundle"
ASIDE="$BUILD_BUNDLE.aside-$$"

main() {
  [[ -d "$BUILD_BUNDLE" ]] || { echo "missing $BUILD_BUNDLE (build first)" >&2; exit 2; }
  mkdir -p "$OUT_BASE"
  local marker run
  marker="$(mktemp)"
  mv "$BUILD_BUNDLE" "$ASIDE"
  trap 'mv "'"$ASIDE"'" "'"$BUILD_BUNDLE"'"; rm -f "'"$marker"'"' EXIT
  caffeinate -u -d -t 120 &
  open -n -W "$APP" --args --selftest-only=packaging,input "--standalone-check=$BUILD_BUNDLE"
  run="$(find "$OUT_BASE" -mindepth 1 -maxdepth 1 -type d -newer "$marker" | sort | tail -1)"
  [[ -n "$run" && -f "$run/report.json" ]] || { echo "no report: the app crashed or never started" >&2; exit 1; }
  python3 - "$run/report.json" <<'PY'
import json, sys
results = {r["id"]: r for r in json.load(open(sys.argv[1]))["results"]}
for key in ("PK-01a", "PK-01b"):
    print(f'{key} {results[key]["status"]} {json.dumps(results[key]["evidence"], ensure_ascii=False)}')
inputs = [r for k, r in results.items() if k.startswith("IN-") and len(k) > 5 and r["status"] != "unverified"]
failed = [r["id"] for r in inputs if r["status"] == "fail"]
print(f'input subs measured={len(inputs)} failed={failed}')
print(f'PK-01: {results["PK-01"]["status"]}')
sys.exit(0 if results["PK-01"]["status"] == "pass" and not failed else 1)
PY
}

main "$@"
