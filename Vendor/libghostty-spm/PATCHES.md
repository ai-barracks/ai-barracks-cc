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

4. **Ordered backlog notifications** (`InMemory/InMemoryTerminalSurfaceAccess.swift`,
   `unlockNotifyingBacklog`): a backlog change was computed under the lock
   but its handler ran after unlock, so two threads could deliver `true` and
   `false` in reverse order and leave the host's transport paused for good
   (Codex r4). Changes are queued under the state lock in the order they
   were computed and one thread at a time delivers the queue in order, with
   no lock held, so a handler may still call back into the session (a first
   version held a notification lock across the handler and deadlocked on
   re-entry, Codex r6).

5. **Replay writes and output-stream markers**
   (`InMemory/InMemoryTerminalSession.swift` `receiveReplay`, `enqueueMarker`;
   `InMemoryTerminalSurfaceAccess`; pending operations `.replay`, `.marker`):
   - `receiveReplay` queues reattach history in order with live output and
     parses it with `ghostty_surface_write_buffer_replay` (the C entry point
     upstream patch 0011 added, which the Swift wrapper did not expose), so the
     replies its queries would cause are suppressed at their origin. The host
     used to mute its input until a poll saw the queue drained: a poll could
     run before the replay arrived, and replies the surface delivers through
     the app mailbox reached the host after the unmute (Codex r4; PS-04a
     measured the replayed DA answered again).
   - `enqueueMarker` runs a block on the output queue once everything queued
     before it is parsed — the host archives an ended program's screen only
     after its last output (Codex r4).

Upstream candidates: patch 1 (a resolver that also checks `resourceURL`), patch 4, patch 5.
