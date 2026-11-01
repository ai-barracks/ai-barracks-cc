#!/usr/bin/env bash
# Packages AIBCC-Bench.app, the helper that drives other apps with real input
# events (ST-02 v1.6.1 baseline, RS-06 Claude Code TUI comparison). It is
# granted Accessibility on its own, so the agent's terminal never needs it.
# The grant of an ad-hoc signed app is tied to its code hash: rebuilding this
# bundle means granting again. Pass --force to rebuild anyway.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/AIBCC-Bench.app"

if [[ -d "$APP" && "${1:-}" != "--force" ]]; then
  echo "kept existing $APP (its Accessibility grant would not survive a rebuild); --force to rebuild"
  exit 0
fi
if [[ -z "${SWIFTPM_CUSTOM_LIBS_DIR:-}" && -d "$ROOT/.toolchain-fix" ]]; then
  export SWIFTPM_CUSTOM_LIBS_DIR="$ROOT/.toolchain-fix"
fi
swift build -c debug --package-path "$ROOT" --disable-keychain --product AIBCCBench
BIN="$(swift build -c debug --package-path "$ROOT" --disable-keychain --show-bin-path)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/AIBCCBench" "$APP/Contents/MacOS/AIBCCBench"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.aibarracks.bench</string>
  <key>CFBundleName</key><string>AIBCC-Bench</string>
  <key>CFBundleExecutable</key><string>AIBCCBench</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "built: $APP"
