#!/usr/bin/env bash
# npm audit gate shared by ci.yml and release.yml.
#
# Policy (Claude + Codex council, 2026-10-15 — tracking: ai-barracks/ai-barracks-cc#18):
# - Production dependencies: any high/critical advisory blocks.
# - Full tree (build tools included): high/critical advisories listed in KNOWN_ADVISORIES
#   only warn until EXPIRY. Any other high/critical advisory, an unparsable audit result,
#   or a passed EXPIRY blocks.
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

echo "== Production dependency audit (blocks on high/critical)"
npm audit --omit=dev --audit-level=high

echo "== Full dependency audit (listed build-tool advisories warn until ${EXPIRY})"
if [[ "$TODAY" > "$EXPIRY" ]]; then
    echo "::error title=npm audit::Build-tool advisory exception expired on ${EXPIRY}. Re-decide in ai-barracks/ai-barracks-cc#18."
    exit 1
fi

npm audit --json > "$REPORT" || true   # non-zero whenever vulnerabilities exist
if ! jq -e '.metadata.vulnerabilities | type == "object"' "$REPORT" >/dev/null 2>&1; then
    echo "::error title=npm audit::Full audit did not produce a parsable report (see ${REPORT})."
    exit 1
fi

unlisted="$(jq -r --argjson known "$KNOWN_ADVISORIES" '
    [.vulnerabilities[] | select(.severity == "high" or .severity == "critical")
     | .via[] | objects | .url]
    | unique | map(select(. as $u | $known | index($u) | not)) | join(" ")' "$REPORT")"
if [ -n "$unlisted" ]; then
    echo "::error title=npm audit::Unlisted high/critical advisories: ${unlisted}"
    exit 1
fi

counts="$(jq -c '.metadata.vulnerabilities' "$REPORT")"
if jq -e '.metadata.vulnerabilities | (.high + .critical) > 0' "$REPORT" >/dev/null; then
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
