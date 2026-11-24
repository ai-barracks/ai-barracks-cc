#!/usr/bin/env python3
"""Merge human / review evidence into one self-test report and re-judge it.

usage: merge-evidence.py RUN_DIR EVIDENCE.json [EVIDENCE.json ...]

EVIDENCE is a JSON list of {"id", "status": "pass"|"fail", "reviewer",
"note", optional "run"} or {"id", "from_run"}: the latter copies a result
measured by another automated run (e.g. PK-01b from
scripts/verify-standalone.sh) after checking that run's report.json. A
review of captures taken by a dedicated run (e.g. RS-06 from
--selftest-only=rs06) names it in "source_run" with its "captures"; the
directory and every listed capture must exist. An entry only fills a sub-result that the run left
`unverified` — measured results are never overwritten. An entry whose "run"
names a different run directory is rejected (capture reviews belong to the
run that produced the captures). Parents are re-aggregated with the same
rule as the app (CriteriaCatalog.aggregate): fail if any required or
optional sub failed, pass only if every required sub passed.

Writes RUN_DIR/report.merged.json and prints the verdict; exit codes match
the app (0 all blocking pass, 1 blocking fail, 3 incomplete).
"""

import json
import os
import sys


def linked_result(entry, base):
    report = os.path.join(base, entry["from_run"], "report.json")
    found = {r["id"]: r for r in json.load(open(report, encoding="utf-8"))["results"]}.get(entry["id"])
    if not found or found["status"] == "unverified":
        sys.exit(f"{entry['id']}: not measured in {entry['from_run']}")
    return {**entry, "status": found["status"], "reviewer": "measured",
            "note": f"from run {entry['from_run']}: {json.dumps(found['evidence'], ensure_ascii=False)[:300]}"}


def load_evidence(paths, run_name, base):
    entries = {}
    for path in paths:
        for entry in json.load(open(path, encoding="utf-8")):
            if entry.get("from_run"):
                entry = linked_result(entry, base)
            if entry.get("source_run"):
                source = os.path.join(base, entry["source_run"])
                missing = [c for c in entry.get("captures", []) if not os.path.exists(os.path.join(source, c))]
                if not os.path.isdir(source) or missing:
                    sys.exit(f"{path}: {entry['id']} source run {entry['source_run']} missing {missing or 'directory'}")
            if entry.get("run") and entry["run"] != run_name:
                sys.exit(f"{path}: {entry['id']} belongs to run {entry['run']}, not {run_name}")
            if entry["status"] not in ("pass", "fail"):
                sys.exit(f"{path}: {entry['id']} has status {entry['status']}")
            entries[entry["id"]] = {**entry, "source": os.path.basename(path)}
    return entries


def merge_subs(results, evidence):
    merged, applied = [], []
    for result in results:
        entry = evidence.get(result["id"])
        if entry and result["status"] == "unverified" and not is_parent(result):
            result = {**result, "status": entry["status"],
                      "evidence": {**result["evidence"], "reviewer": entry.get("reviewer", ""),
                                   "note": entry.get("note", ""), "evidence_file": entry["source"]}}
            applied.append(result["id"])
        merged.append(result)
    return merged, applied


def is_parent(result):
    return "requires" in result["evidence"]


def aggregate(results):
    subs = {r["id"]: r for r in results if not is_parent(r)}
    out = []
    for result in results:
        if not is_parent(result):
            out.append(result)
            continue
        required = [x for x in result["evidence"]["requires"].split(",") if x]
        optional = [x for x in result["evidence"].get("optional", "").split(",") if x]
        found = [subs[x] for x in required if x in subs]
        failed = any(subs[x]["status"] == "fail" for x in optional if x in subs) \
            or any(r["status"] == "fail" for r in found)
        passed = len(found) == len(required) and all(r["status"] == "pass" for r in found)
        status = "fail" if failed else "pass" if passed else "unverified"
        out.append({**result, "status": status})
    return out


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    run_dir = sys.argv[1].rstrip("/")
    report = json.load(open(os.path.join(run_dir, "report.json"), encoding="utf-8"))
    evidence = load_evidence(sys.argv[2:], os.path.basename(run_dir), os.path.dirname(run_dir))
    results, applied = merge_subs(report["results"], evidence)
    results = aggregate(results)
    unused = sorted(set(evidence) - set(applied))
    merged = {**report, "results": results, "merged_evidence": applied, "unused_evidence": unused}
    with open(os.path.join(run_dir, "report.merged.json"), "w", encoding="utf-8") as out:
        json.dump(merged, out, ensure_ascii=False, indent=2, sort_keys=True)
    blocking = [r for r in results if is_parent(r) and r["evidence"].get("blocking") == "true"]
    counts = {s: sum(r["status"] == s for r in blocking) for s in ("pass", "fail", "unverified")}
    print(f"applied={applied} unused={unused}")
    print(f"blocking: {counts}")
    print("unverified:", " ".join(r["id"] for r in blocking if r["status"] == "unverified"))
    print("failed:", " ".join(r["id"] for r in blocking if r["status"] == "fail") or "-")
    sys.exit(1 if counts["fail"] else 3 if counts["unverified"] else 0)


if __name__ == "__main__":
    main()
