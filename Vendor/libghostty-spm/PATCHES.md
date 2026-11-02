# AIBCC patches to libghostty-spm

Vendored from https://github.com/Lakr233/libghostty-spm tag `2.2.2026103001`
(commit `3404c8a2e6403d0a5e730eb08abdaa1c865a83e9`, Ghostty upstream
`1e9e14af5df1`, MIT — see LICENSE). Only `Sources/`, `Package.swift`,
`LICENSE` and `Ghostty.ref` are copied; the prebuilt GhosttyKit.xcframework is
still fetched by the unchanged `binaryTarget` URL + checksum.

1. **Resource bundle lookup** (`GhosttyRuntimeResources.swift`,
   `GhosttyResourceBundle`): SwiftPM's generated `Bundle.module` looks only at
   the `.app` root and the absolute build path and `fatalError`s otherwise, so
   a shipped app crashed (AIBCC known issue #1). Resolve
   `Bundle.main.resourceURL/GhosttyKit_GhosttyTerminal.bundle` first and keep
   `Bundle.module` as the fallback for `swift run`. Every `bundle: .module`
   (localized menu titles) uses the same resolver. Adds
   `GhosttyRuntimeResources.bundleURL` so the host can verify the source.
2. The `GhosttyKitTest` test target is removed (tests are not vendored).
3. **Full screen text** (`Surface/TerminalSurface+ScreenText.swift`):
   `AppTerminalView.readScreenText()` reads scrollback + viewport through
   `ghostty_surface_read_text` (SCREEN top-left to bottom-right) for the
   app's "export output" (CC v1 parity). Read-only; no input, no selection
   change.

Upstream candidate: patch 1 (a resolver that also checks `resourceURL`).
