#!/usr/bin/env bash
# Bundle the Markdown renderer (micromark + GFM) into Renderer/dist.
# The renderer is a standalone HTML/JS bundle so the same files can be reused
# by the Tauri app if the Swift PoC ends in No-go (Council 20261031_153914).
# Uses an existing node_modules that already contains esbuild + micromark;
# no network access is needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_MODULES="${AIBCC_NODE_MODULES:?set AIBCC_NODE_MODULES to a node_modules with esbuild, micromark, micromark-extension-gfm}"
OUT="$ROOT/Renderer/dist"

mkdir -p "$OUT"
NODE_PATH="$NODE_MODULES" "$NODE_MODULES/.bin/esbuild" \
  "$ROOT/Renderer/src/render.js" \
  --bundle --format=iife --minify --target=safari17 \
  --outfile="$OUT/renderer.js"
cp "$ROOT/Renderer/src/index.html" "$ROOT/Renderer/src/style.css" "$OUT/"
echo "renderer bundled: $OUT"
