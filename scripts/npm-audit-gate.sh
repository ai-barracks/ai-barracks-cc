#!/usr/bin/env bash
# npm audit gate shared by ci.yml and release.yml.
#
# Policy (Claude + Codex council, 2026-10-15 — tracking: ai-barracks/ai-barracks-cc#18):
# - Production dependencies: any high/critical advisory blocks.
# - Full tree (build tools included): high/critical advisories listed in KNOWN_ADVISORIES
#   only warn until EXPIRY. An unlisted high/critical advisory, an entry that cannot be
#   traced to an advisory, an unparsable or inconsistent report, or a passed EXPIRY blocks.
#
# KNOWN_ADVISORIES is keyed by advisory URL, not package name, so a new advisory on an
# already-flagged package still blocks. braces has no patched release and reaches us only
# through the Tailwind 3 build chain (braces <- micromatch <- fast-glob/chokidar <-
# tailwindcss), which runs at build time on developer-controlled globs and is not bundled.
# Remove the entry and make the full audit blocking again once Tailwind 4 lands.
set -euo pipefail

EXPIRY="2027-01-15"
KNOWN_ADVISORIES='["https://github.com/advisories/GHSA-vfj7-8cjw-p6xm"]'
TODAY="${NPM_AUDIT_TODAY:-$(date -u +%F)}"   # override only for tests
REPORT="${NPM_AUDIT_REPORT:-npm-audit-full.json}"

# Emits "ERROR <reason>" lines for anything that must block, then "COUNTS <json>" and,
# when high/critical entries remain, "WARN". Severity is judged per advisory object:
# a package's severity is the max of its advisories, so a listed high advisory may sit
# beside an unlisted moderate one on the same package without blocking.
POLICY='
def hc: . == "high" or . == "critical";
def count: type == "number" and . >= 0 and floor == .;
.vulnerabilities as $v
| .metadata.vulnerabilities as $m
| if ($v | type) != "object" or ($m | type) != "object" then
    "ERROR report has no vulnerabilities/metadata objects"
  elif ([$m.info, $m.low, $m.moderate, $m.high, $m.critical, $m.total] | all(count) | not) then
    "ERROR metadata counts are missing or not non-negative integers"
  else
    ([$v | to_entries[] | select(.value.severity | hc)]) as $hc_pkgs
    | ([$v[] | (.via // [])[] | objects | select(.severity | hc)]) as $hc_advisories
    | ([$hc_advisories[] | .url | select(type == "string" and . != "")] | unique) as $urls
    | ([$urls[] | select(. as $u | $known | any(. == $u) | not)]) as $unlisted
    | (if ($hc_pkgs | map(select(.value.severity == "high")) | length) != $m.high
          or ($hc_pkgs | map(select(.value.severity == "critical")) | length) != $m.critical
       then "ERROR metadata high/critical counts disagree with the vulnerability entries" else empty end),
      (if ($hc_advisories | map(select((.url | type) != "string" or .url == "")) | length) > 0
       then "ERROR high/critical advisory without a URL" else empty end),
      ($v | to_entries[] | .key as $k | (.value.via // [])[] | strings | select($v[.] == null)
       | "ERROR \($k) refers to \(.), which is not in the report"),
      ($hc_pkgs[] | select(((.value.via // []) | length) == 0) | "ERROR \(.key) is high/critical with no advisory"),
      (if ($hc_pkgs | length) > 0 and ($hc_advisories | length) == 0
       then "ERROR high/critical packages without any high/critical advisory" else empty end),
      (if ($unlisted | length) > 0 then "ERROR unlisted high/critical advisories: \($unlisted | join(" "))" else empty end),
      "COUNTS \($m | tojson)",
      (if ($m.high + $m.critical) > 0 then "WARN" else empty end)
  end
'

# Collect the full report first, so it exists (and is uploaded) even when a check blocks.
echo "== Full npm audit report -> ${REPORT}"
npm audit --json > "$REPORT" || true   # non-zero whenever vulnerabilities exist

echo "== Production dependency audit (blocks on high/critical)"
npm audit --omit=dev --audit-level=high

echo "== Full dependency audit (listed build-tool advisories warn until ${EXPIRY})"
if [[ "$TODAY" > "$EXPIRY" ]]; then
    echo "::error title=npm audit::Build-tool advisory exception expired on ${EXPIRY}. Re-decide in ai-barracks/ai-barracks-cc#18."
    exit 1
fi

if ! verdict="$(jq -r --argjson known "$KNOWN_ADVISORIES" "$POLICY" "$REPORT" 2>&1)"; then
    echo "::error title=npm audit::Full audit report could not be evaluated: ${verdict}"
    exit 1
fi
blocked=false
while IFS= read -r line; do
    case "$line" in
        "ERROR "*) echo "::error title=npm audit::${line#ERROR }"; blocked=true ;;
    esac
done <<< "$verdict"
$blocked && exit 1

counts=""
warn=false
while IFS= read -r line; do
    case "$line" in
        "COUNTS "*) counts="${line#COUNTS }" ;;
        WARN) warn=true ;;
    esac
done <<< "$verdict"
if [ -z "$counts" ]; then
    echo "::error title=npm audit::Full audit evaluation produced no counts."
    exit 1
fi

if $warn; then
    echo "::warning title=npm audit (build tools)::Listed build-tool advisories remain until ${EXPIRY} (ai-barracks/ai-barracks-cc#18): ${counts}"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### npm audit (full tree)"
        echo
        echo "Counts: \`${counts}\`"
        echo
        echo "Listed build-tool advisories warn until ${EXPIRY}: ${KNOWN_ADVISORIES} (ai-barracks/ai-barracks-cc#18)"
    } >> "$GITHUB_STEP_SUMMARY"
fi
echo "npm audit gate passed: ${counts}"
