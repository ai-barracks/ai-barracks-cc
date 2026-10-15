#!/usr/bin/env bash
# Tests for scripts/npm-audit-gate.sh with a stubbed npm (no network).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/scripts/npm-audit-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/npm" <<'SH'
#!/usr/bin/env bash
# `npm audit --omit=dev ...` → exit STUB_PROD_RC; `npm audit --json` → cat STUB_FULL_JSON.
case " $* " in
    *" --omit=dev "*) exit "${STUB_PROD_RC:-0}" ;;
    *" --json "*) cat "$STUB_FULL_JSON"; exit 1 ;;   # npm exits non-zero when vulns exist
esac
exit 2
SH
chmod +x "$TMP/bin/npm"

KNOWN_URL="https://github.com/advisories/GHSA-vfj7-8cjw-p6xm"
report() {  # report <high> <advisory-url-or-empty>
    local high="$1" url="$2" vulns='{}'
    if [ -n "$url" ]; then
        vulns="{\"braces\":{\"severity\":\"high\",\"via\":[{\"url\":\"$url\",\"severity\":\"high\"}]},
                \"micromatch\":{\"severity\":\"high\",\"via\":[\"braces\"]}}"
    fi
    printf '{"vulnerabilities":%s,"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":%s,"critical":0,"total":%s}}}' \
        "$vulns" "$high" "$high"
}
run_gate() { (cd "$TMP" && PATH="$TMP/bin:$PATH" GITHUB_STEP_SUMMARY="$TMP/summary.md" \
    NPM_AUDIT_REPORT="$TMP/report.json" bash "$GATE") > "$TMP/out.log" 2>&1; }
fail() { echo "FAIL: $*"; cat "$TMP/out.log"; exit 1; }
pass() { echo "PASS: $*"; }

report 2 "$KNOWN_URL" > "$TMP/known.json"
STUB_FULL_JSON="$TMP/known.json" NPM_AUDIT_TODAY=2026-10-15 run_gate || fail "known advisory should pass"
grep -q '::warning' "$TMP/out.log" || fail "known advisory should surface a warning"
grep -q 'npm audit (full tree)' "$TMP/summary.md" || fail "step summary missing"
pass "known build-tool advisory passes with a warning and a step summary"

report 1 "https://github.com/advisories/GHSA-new0-0000-0000" > "$TMP/unknown.json"
if STUB_FULL_JSON="$TMP/unknown.json" NPM_AUDIT_TODAY=2026-10-15 run_gate; then fail "unlisted advisory must block"; fi
grep -q 'GHSA-new0-0000-0000' "$TMP/out.log" || fail "error should name the unlisted advisory"
pass "unlisted high/critical advisory blocks"

echo '{"error":{"code":"ENOTFOUND"}}' > "$TMP/broken.json"
if STUB_FULL_JSON="$TMP/broken.json" NPM_AUDIT_TODAY=2026-10-15 run_gate; then fail "unparsable report must block"; fi
pass "unparsable full audit blocks"

if STUB_FULL_JSON="$TMP/known.json" NPM_AUDIT_TODAY=2027-01-16 run_gate; then fail "expired exception must block"; fi
STUB_FULL_JSON="$TMP/known.json" NPM_AUDIT_TODAY=2027-01-15 run_gate || fail "expiry day itself is still allowed"
pass "exception blocks after its expiry date"

if STUB_PROD_RC=1 STUB_FULL_JSON="$TMP/known.json" NPM_AUDIT_TODAY=2026-10-15 run_gate; then fail "production audit failure must block"; fi
pass "production high/critical blocks"

report 0 "" > "$TMP/clean.json"
STUB_FULL_JSON="$TMP/clean.json" NPM_AUDIT_TODAY=2026-10-15 run_gate || fail "clean tree should pass"
grep -q '::warning' "$TMP/out.log" && fail "clean tree must not warn"
pass "clean tree passes without warnings"

meta() {  # meta <moderate> <high>
    printf '"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":%s,"high":%s,"critical":0,"total":%s}}' "$1" "$2" "$(( $1 + $2 ))"
}
blocks() {  # blocks <name> <json>
    printf '%s' "$2" > "$TMP/case.json"
    if STUB_FULL_JSON="$TMP/case.json" NPM_AUDIT_TODAY=2026-10-15 run_gate; then fail "$1 must block"; fi
}

blocks "high advisory without url" "{\"vulnerabilities\":{\"x\":{\"severity\":\"high\",\"via\":[{\"severity\":\"high\",\"title\":\"no url\"}]}},$(meta 0 1)}"
blocks "high package via a missing package" "{\"vulnerabilities\":{\"x\":{\"severity\":\"high\",\"via\":[\"ghost\"]}},$(meta 0 1)}"
blocks "high package with no via" "{\"vulnerabilities\":{\"x\":{\"severity\":\"high\",\"via\":[]}},$(meta 0 1)}"
pass "unexplained high/critical entries block"

blocks "non-numeric counts" "{\"vulnerabilities\":{},\"metadata\":{\"vulnerabilities\":{\"high\":\"one\",\"critical\":0}}}"
blocks "empty metadata" '{"vulnerabilities":{},"metadata":{"vulnerabilities":{}}}'
blocks "counts disagree with entries" "{\"vulnerabilities\":{},$(meta 0 1)}"
pass "malformed or inconsistent metadata blocks"

printf '%s' "{\"vulnerabilities\":{\"braces\":{\"severity\":\"high\",\"via\":[{\"url\":\"$KNOWN_URL\",\"severity\":\"high\"},{\"url\":\"https://github.com/advisories/GHSA-mod0-0000-0000\",\"severity\":\"moderate\"}]}},$(meta 0 1)}" > "$TMP/mixed.json"
STUB_FULL_JSON="$TMP/mixed.json" NPM_AUDIT_TODAY=2026-10-15 run_gate || fail "an unlisted moderate advisory beside a listed high must not block"
pass "only advisories that are themselves high/critical need listing"

rm -f "$TMP/report.json"
if STUB_PROD_RC=1 STUB_FULL_JSON="$TMP/known.json" NPM_AUDIT_TODAY=2026-10-15 run_gate; then fail "production failure must block"; fi
[ -s "$TMP/report.json" ] || fail "full report must exist even when the production audit blocks"
rm -f "$TMP/report.json"
if STUB_FULL_JSON="$TMP/known.json" NPM_AUDIT_TODAY=2027-02-01 run_gate; then fail "expired exception must block"; fi
[ -s "$TMP/report.json" ] || fail "full report must exist even when the exception expired"
pass "full report is written before any blocking decision"

echo "All npm audit gate tests passed."
