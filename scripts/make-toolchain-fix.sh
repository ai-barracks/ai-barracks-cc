#!/usr/bin/env bash
# Works around a broken Command Line Tools install without touching system
# files: stale `*.private.swiftinterface` files from a 2024 CLT survive in
# usr/lib/swift/pm/{ManifestAPI,PluginAPI}. swiftc prefers the private
# interface, so manifests compile against the old PackageDescription API and
# then fail to link against the current libPackageDescription.dylib
# ("Undefined symbols ... Package.__allocating_init").
#
# This script mirrors both directories into .toolchain-fix/ with only the
# current public interfaces (dylibs are symlinked). Point SwiftPM at it with
# SWIFTPM_CUSTOM_LIBS_DIR. The real fix is reinstalling the CLT or removing
# the stale files (needs admin) — see docs/known-issues.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLT_PM="${CLT_PM:-/Library/Developer/CommandLineTools/usr/lib/swift/pm}"
FIX="$ROOT/.toolchain-fix"

mirror_api() {
  local name="$1" source="$CLT_PM/$1" target="$FIX/$1" entry module
  mkdir -p "$target"
  for entry in "$source"/*; do
    local base
    base="$(basename "$entry")"
    if [[ -d "$entry" && "$base" == *.swiftmodule ]]; then
      module="$target/$base"
      rm -rf "$module"
      mkdir -p "$module"
      find "$entry" -maxdepth 1 -type f ! -name '*.private.swiftinterface' -exec cp {} "$module/" \;
    else
      ln -sfn "$entry" "$target/$base"
    fi
  done
  echo "mirrored $name -> $target"
}

needs_fix() {
  [[ -n "$(find "$CLT_PM" -name '*.private.swiftinterface' -print -quit 2>/dev/null)" ]]
}

main() {
  if ! needs_fix; then
    echo "CLT has no stale private interfaces; no fix needed"
    exit 0
  fi
  mirror_api ManifestAPI
  mirror_api PluginAPI
  echo "export SWIFTPM_CUSTOM_LIBS_DIR=$FIX"
}

main "$@"
