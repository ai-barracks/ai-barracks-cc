#!/usr/bin/env bash
# Build AIBCCPoC with SwiftPM (Command Line Tools only) and wrap it in an
# ad-hoc signed .app. The PoC must always run as an .app so TSM/IME and
# resource lookup behave like a shipped app (acceptance-criteria §8).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-debug}"
MIN_FREE_GB="${MIN_FREE_GB:-3}"
DATA_VOLUME="${DATA_VOLUME:-/System/Volumes/Data}"
APP_NAME="AIBCC-PoC"
EXEC_NAME="AIBCCPoC"
DAEMON_NAME="AIBCCPtyDaemon"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

free_gb() {
  df -g "$DATA_VOLUME" | awk 'NR==2 { print $4 }'
}

require_disk() {
  local stage="$1" free
  free="$(free_gb)"
  if (( free < MIN_FREE_GB )); then
    echo "abort($stage): ${free}GB free < ${MIN_FREE_GB}GB" >&2
    exit 2
  fi
  echo "disk($stage): ${free}GB free"
}

use_toolchain_fix() {
  # Stale 2024 private interfaces in the CLT break manifest compilation on
  # this Mac (docs/known-issues.md #9). Route SwiftPM to a sanitized mirror.
  if [[ -z "${SWIFTPM_CUSTOM_LIBS_DIR:-}" ]] \
     && [[ -n "$(find /Library/Developer/CommandLineTools/usr/lib/swift/pm -name '*.private.swiftinterface' -print -quit 2>/dev/null)" ]]; then
    "$ROOT/scripts/make-toolchain-fix.sh" >&2
    export SWIFTPM_CUSTOM_LIBS_DIR="$ROOT/.toolchain-fix"
  fi
}

build_binary() {
  # Build first as its own command so a compile failure stops the script
  # instead of being masked by a later successful --show-bin-path.
  # --disable-keychain: without it SwiftPM blocks on a keychain lookup for
  # github.com while downloading the binary artifact (observed 2026-10-31).
  swift build -c "$CONFIG" --package-path "$ROOT" --disable-keychain
}

bin_path() {
  swift build -c "$CONFIG" --package-path "$ROOT" --disable-keychain --show-bin-path
}

assemble_bundle() {
  local bin_dir="$1"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$bin_dir/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"
  # PTY daemon helper (opt-in --backend=daemon); the app finds it next to itself.
  cp "$bin_dir/$DAEMON_NAME" "$APP/Contents/MacOS/$DAEMON_NAME"
  cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
  # SwiftPM resource bundles (libghostty-spm Ghostty resources, terminfo).
  local bundle
  for bundle in "$bin_dir"/*.bundle; do
    [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
  done
  cp -R "$ROOT/Renderer/dist" "$APP/Contents/Resources/MarkdownRenderer"
  cp -R "$ROOT/Fixtures" "$APP/Contents/Resources/Fixtures"
}

sign_bundle() {
  # Nested code is signed before the outer app; --deep is not used.
  local nested
  while IFS= read -r -d '' nested; do
    codesign --force --sign - "$nested"
  done < <(find "$APP/Contents" -type d -name '*.framework' -print0)
  codesign --force --sign - "$APP/Contents/MacOS/$DAEMON_NAME"
  codesign --force --sign - "$APP"
  codesign --verify --strict --verbose=1 "$APP"
}

write_build_info() {
  local ghostty_ref
  ghostty_ref="$(find "$ROOT/.build/checkouts" -maxdepth 2 -name Ghostty.ref -exec cat {} \; 2>/dev/null | head -1 || true)"
  cat > "$DIST/build-info.json" <<JSON
{
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "config": "$CONFIG",
  "swift": "$(swift --version 2>&1 | head -1 | sed 's/"/\\"/g')",
  "libghostty_spm": "2.2.2026103001",
  "ghostty_upstream_ref": "${ghostty_ref:-unknown}",
  "app_size_kb": $(du -sk "$APP" | awk '{print $1}'),
  "build_dir_size_kb": $(du -sk "$ROOT/.build" | awk '{print $1}'),
  "disk_free_gb": $(free_gb)
}
JSON
  cat "$DIST/build-info.json"
}

main() {
  require_disk start
  mkdir -p "$DIST"
  use_toolchain_fix
  build_binary
  local bin_dir
  bin_dir="$(bin_path)"
  assemble_bundle "$bin_dir"
  sign_bundle
  write_build_info
  require_disk end
  echo "built: $APP"
}

main "$@"
