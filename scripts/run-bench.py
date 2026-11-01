#!/usr/bin/env python3
"""External-input benchmarks across terminals, driven by AIBCC-Bench.app.

usage:
  run-bench.py latency [TARGET ...]   ST-02 baseline: input latency during a flood
  run-bench.py rs06 [TARGET ...]      RS-06: Claude Code TUI through a resize sequence
  run-bench.py probe TARGET           launch + capture only (to see a window's layout)

TARGETs: poc, v161, terminal, iterm (default: all). Every target gets the
same window frame and the same sequence. Keys are real HID events, so the
PoC is measured on the same path as the others (the in-app ST-02 posts
events inside the process instead). Requires scripts/capture-watcher.sh for
captures and the AIBCC-Bench Accessibility grant. Do not touch the keyboard
or mouse while it runs.
"""

import json
import os
import subprocess
import sys
import time
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH = os.path.join(ROOT, "dist", "AIBCC-Bench.app")
FLOOD = os.path.join(ROOT, "Fixtures", "flood_recorder.py")
OUT_BASE = os.path.expanduser("~/Library/Application Support/AIBCCPoC/selftest")
FRAME = {"x": 120, "y": 80, "w": 1200, "h": 800}
RS06_SIZES = [(900, 700), (600, 500), (1200, 800), (500, 400), (1200, 800)]
RS06_DIR = "/tmp/aibcc-rs06"
LATENCY_KEYS = 80
KEY_INTERVAL_MS = 6
MIN_VALID_SAMPLES = 15

# Where a click lands on the terminal (fraction of the window frame).
TARGETS = {
    "poc": {"bundle": "com.aibarracks.commandcenter.swiftpoc", "click": (0.45, 0.55)},
    "v161": {"bundle": "com.aibarracks.commandcenter", "click": (0.55, 0.6)},
    "terminal": {"bundle": "com.apple.Terminal", "click": (0.5, 0.5)},
    "iterm": {"bundle": "com.googlecode.iterm2", "click": (0.5, 0.5)},
}


def prepare(target):
    spec = TARGETS[target]
    rx, ry = spec["click"]
    return [
        {"op": "launch", "bundle": spec["bundle"]},
        {"op": "front", "bundle": spec["bundle"]},
        {"op": "frame", "bundle": spec["bundle"], **FRAME},
        {"op": "wait", "ms": 1200},
        {"op": "click", "bundle": spec["bundle"], "rx": rx, "ry": ry},
        {"op": "wait", "ms": 300},
    ]


def run_steps(target, kind, steps):
    run_dir = os.path.join(OUT_BASE, f"bench-{kind}-{target}-{time.strftime('%Y%m%dT%H%M%S')}")
    os.makedirs(run_dir, exist_ok=True)
    script = os.path.join(run_dir, "script.json")
    result = os.path.join(run_dir, "result.json")
    with open(script, "w") as handle:
        json.dump({"captureDir": run_dir, "steps": steps}, handle, indent=2)
    subprocess.run(["open", "-n", "-W", BENCH, "--args", "--script", script, "--out", result], check=False)
    data = json.load(open(result)) if os.path.exists(result) else {"ok": False, "log": [], "sent": []}
    failed = [entry for entry in data.get("log", []) if not entry["ok"]]
    print(f"[{target}] {kind}: steps ok={data.get('ok')} failed={[(f['op'], f['detail']) for f in failed]}")
    return run_dir, data


def latency(target):
    token = uuid.uuid4().hex[:8]
    log = f"/tmp/aibcc-bench-flood-{target}-{token}.jsonl"
    go = f"/tmp/aibcc-bench-go-{target}-{token}"
    command = f"clear; env FLOOD_LINES=100000 AIBCC_GO_FILE={go} /usr/bin/python3 {FLOOD} {log}"
    bundle = TARGETS[target]["bundle"]
    steps = prepare(target) + [
        {"op": "type", "text": command},
        {"op": "key", "key": "return"},
        {"op": "waitFile", "path": log, "contains": "\"ready\"", "ms": 15000},
        {"op": "wait", "ms": 500},
        {"op": "burst", "goFile": go, "path": log, "count": LATENCY_KEYS, "intervalMs": KEY_INTERVAL_MS},
        {"op": "waitFile", "path": log, "contains": "\"flood_done\"", "ms": 60000},
        {"op": "wait", "ms": 1500},
        {"op": "capture", "bundle": bundle, "label": "after-flood"},
        {"op": "key", "key": "ctrl-d"},
        {"op": "wait", "ms": 500},
    ]
    run_dir, data = run_steps(target, "latency", steps)
    stats = judge(data.get("sent", []), log)
    stats["run"] = os.path.basename(run_dir)
    with open(os.path.join(run_dir, "latency.json"), "w") as handle:
        json.dump(stats, handle, indent=2)
    print(f"[{target}] {json.dumps(stats)}")
    return stats


def judge(sent, log_path):
    """Same rules as LoadSuite.verdict: only keys sent while the flood ran."""
    events = [json.loads(line) for line in open(log_path)] if os.path.exists(log_path) else []
    first = lambda kind: next((e for e in events if e["kind"] == kind), None)
    start = (first("flood_start") or {}).get("wall", float("inf"))
    done = (first("flood_done") or {}).get("wall", float("inf"))
    arrivals = [(byte, e.get("wall")) for e in events if e["kind"] == "bytes"
                for byte in bytes.fromhex(e["hex"].replace(" ", ""))]
    ordered = [b for b, _ in arrivals] == [s["byte"] for s in sent]
    pairs = [(s, a) for s, a in zip(sent, arrivals) if start <= s["wall"] <= done]
    latencies = sorted((a[1] - s["wall"]) * 1000 for s, a in pairs if a[1] is not None)
    stats = {"sent": len(sent), "received": len(arrivals), "ordered": ordered,
             "samples_during_flood": len(latencies),
             "flood_ms": round((done - start) * 1000) if done != float("inf") else None}
    if latencies and len(latencies) >= MIN_VALID_SAMPLES:
        pick = lambda f: latencies[min(len(latencies) - 1, int(len(latencies) * f))]
        stats.update({"p50_ms": round(pick(0.5), 1), "p95_ms": round(pick(0.95), 1), "max_ms": round(latencies[-1], 1)})
    else:
        stats["verdict"] = "measurement window too short" if ordered else "invalid"
    return stats


def rs06(target):
    bundle = TARGETS[target]["bundle"]
    steps = prepare(target) + [
        {"op": "type", "text": f"clear; mkdir -p {RS06_DIR} && cd {RS06_DIR} && claude"},
        {"op": "key", "key": "return"},
        {"op": "wait", "ms": 7000},
        {"op": "capture", "bundle": bundle, "label": "0-start"},
        # First run in the folder shows the trust dialog; Enter accepts it,
        # and on an empty prompt it does nothing.
        {"op": "key", "key": "return"},
        {"op": "wait", "ms": 3000},
        {"op": "capture", "bundle": bundle, "label": "1-ready"},
    ]
    for index, (width, height) in enumerate(RS06_SIZES, start=2):
        steps += [
            {"op": "frame", "bundle": bundle, "x": FRAME["x"], "y": FRAME["y"], "w": width, "h": height},
            {"op": "wait", "ms": 1500},
            {"op": "capture", "bundle": bundle, "label": f"{index}-{width}x{height}"},
        ]
    steps += [{"op": "key", "key": "ctrl-c"}, {"op": "wait", "ms": 400}, {"op": "key", "key": "ctrl-c"},
              {"op": "wait", "ms": 1500}]
    run_dir, _ = run_steps(target, "rs06", steps)
    print(f"[{target}] captures in {run_dir}")


def probe(target):
    bundle = TARGETS[target]["bundle"]
    run_dir, _ = run_steps(target, "probe", prepare(target) + [{"op": "capture", "bundle": bundle, "label": "layout"}])
    print(run_dir)


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("latency", "rs06", "probe"):
        sys.exit(__doc__)
    targets = sys.argv[2:] or list(TARGETS)
    for target in targets:
        {"latency": latency, "rs06": rs06, "probe": probe}[sys.argv[1]](target)


if __name__ == "__main__":
    main()
