#!/usr/bin/env bash
# Wraps the release app (VARIANT=release ./scripts/package-app.sh) in a
# compressed DMG with an /Applications link. Local only: publishing is a
# separate, explicit step (docs/RELEASE.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="$ROOT/dist/release/AI Barracks CommandCenter 2.app"
DMG="$ROOT/dist/release/AI-Barracks-CommandCenter-$VERSION.dmg"

[[ -d "$APP" ]] || { echo "build first: VARIANT=release ./scripts/package-app.sh" >&2; exit 1; }
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/aibcc-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "CommandCenter $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
shasum -a 256 "$DMG"
