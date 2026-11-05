#!/usr/bin/env bash
# PS-01 (persistence spike): a daemon-owned session survives an app quit and
# the relaunched app reattaches to it. Two launches of the packaged app with
# the daemon backend on a test-only socket, so real sessions are untouched.
#   phase 1  app creates a recorder session, types, saves its identity, quits
#   between  this script checks the process is still alive with no app running
#   phase 2  app restores the grid by itself; PS-01a..d are checked in-app
#   then     PS-04 (replay input fence, archive after the last output) and
#            PS-02 recovery checks (failed attach, daemon stopped or killed)
# Exit 0 only if phase 1's setup passed and PS-01, PS-02 and PS-04 passed in
# phase 2 (Codex r4: a failed phase 1 used to be ignored).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/AIBCC-PoC.app"
DAEMON="$APP/Contents/MacOS/AIBCCPtyDaemon"
SUPPORT="$HOME/Library/Application Support/AIBCCPoC"
SOCKET="${PTYD_SOCKET:-$SUPPORT/ptyd-selftest.sock}"
OUT_BASE="$SUPPORT/selftest"
STATE="$OUT_BASE/persist-state.json"
SHUTDOWN_WAIT_SECONDS=8

stop_daemon() {
  "$DAEMON" --socket "$SOCKET" --shutdown >/dev/null 2>&1 || true
  local waited=0
  while [[ -S "$SOCKET" ]] && (( waited < SHUTDOWN_WAIT_SECONDS * 10 )); do
    sleep 0.1
    waited=$((waited + 1))
  done
}

latest_run() {
  find "$OUT_BASE" -mindepth 1 -maxdepth 1 -type d -newer "$1" -print 2>/dev/null | sort | tail -1
}

run_phase() {
  local phase="$1" marker run
  marker="$(mktemp)"
  open -n -W "$APP" --args "--selftest-only=$phase" --backend=daemon "--ptyd-socket=$SOCKET"
  run="$(latest_run "$marker")"
  rm -f "$marker"
  [[ -n "$run" ]] || { echo "$phase: no report" >&2; exit 2; }
  python3 - "$run/report.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
for result in report["results"]:
    if result["id"].startswith("PS-0") and result["status"] != "unverified":
        print(f'  {result["id"]:12} {result["status"]:5} {json.dumps(result["evidence"], ensure_ascii=False)}')
PY
  echo "$run"
}

main() {
  [[ -x "$DAEMON" ]] || { echo "missing $DAEMON (run scripts/package-app.sh)" >&2; exit 2; }
  mkdir -p "$OUT_BASE"
  caffeinate -u -d -t 300 &
  local caffeinate_pid=$!
  trap 'kill '"$caffeinate_pid"' 2>/dev/null || true; stop_daemon' EXIT

  stop_daemon
  rm -f "$SOCKET.sessions.json" "$STATE"

  echo "phase 1"
  local first
  first="$(run_phase persist1 | tee /dev/stderr | tail -1)"
  [[ -f "$STATE" ]] || { echo "phase 1 wrote no state" >&2; exit 2; }
  python3 - "$first/report.json" <<'PY' || { echo "phase 1 setup failed: phase 2 would prove nothing" >&2; exit 1; }
import json, sys
results = {r["id"]: r["status"] for r in json.load(open(sys.argv[1]))["results"]}
sys.exit(0 if results.get("PS-01-setup") == "pass" else 1)
PY
  local pid
  pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$STATE")"
  if pgrep -f "$APP/Contents/MacOS/AIBCCPoC" >/dev/null; then
    echo "between: app still running" >&2
    exit 2
  fi
  if kill -0 "$pid" 2>/dev/null; then
    echo "between: app quit, session pid $pid alive (parent $(ps -o ppid= -p "$pid" | tr -d ' '))"
  else
    echo "between: session pid $pid died with the app" >&2
  fi
  "$DAEMON" --socket "$SOCKET" --list || echo "between: daemon unreachable" >&2

  echo "phase 2"
  local run
  run="$(run_phase persist2 | tee /dev/stderr | tail -1)"
  python3 - "$run/report.json" <<'PY'
import json, sys
results = {r["id"]: r["status"] for r in json.load(open(sys.argv[1]))["results"]}
wanted = ["PS-01", "PS-02", "PS-04"]
print("  ".join(f"{name}: {results.get(name)}" for name in wanted))
sys.exit(0 if all(results.get(name) == "pass" for name in wanted) else 1)
PY
}

main "$@"
