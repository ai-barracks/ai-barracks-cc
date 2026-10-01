# v1.5.0 release validation

## Goals
1. Runtime-first Codex/Claude model profiles, native interoperability in CLI v1.4 and validated isolated Council results.
2. Default-OFF CommandCenter activation at 06:00 / 11:00 / 16:00 / 21:00 Asia/Seoul: one short request per selected CLI, no application retries or catch-up.

## Release-time acceptance evidence
- CLI: 15 isolated shell regression scripts, including native conversation routing/concurrency/wrapper/trust preservation, skill ownership, structured results/usage and safe profile forwarding.
- Frontend: 101 unit tests and production build.
- Backend: 120 unit tests; Clippy all targets with warnings denied.
- Installed Codex: explicit read-only initialize / initialized / model-list metadata smoke PASS. No thread/turn/model requests.
- npm audit: 0 vulnerabilities after compatible patches. Cargo audit: 0 vulnerabilities; 3 upstream warnings (proc-macro-error/serial unmaintained; glib unsound warning in non-macOS dependency graph).
- Browser mock IPC: activation OFF → confirmation → ON → next KST slot → OFF; no-provider activation rejected.
- Release workflow: regression/security gates, universal macOS package in draft release, publish only after asset inspection.

## Post-release native smoke — 2026-10-01 KST

The desktop was locked during the original release check. After unlock and Accessibility/Screen Recording approval, the **published universal v1.5.0 package** was installed and the native macOS UI was exercised (not the browser mock):

| Check | Observed result |
|---|---|
| Installation | App bundle version 1.5.0; installed executable SHA256 matches the published payload; UI displays CLI v1.4.0 |
| Codex discovery | Read-only app-server model-list succeeds; advertised model/effort can be selected; no model turn |
| Claude profile | Documented alias selection/save succeeds; this is not a live account/model-availability guarantee |
| Persistence | Profiles survive native Quit and relaunch; actual app process absence was checked after Quit |
| Activation | Default OFF → explicit confirmation → ON; next future slot shown as 2026-10-01 11:00 KST → immediately OFF |
| No-provider guard | Final Enable requests button disabled with “Select at least one CLI.” |
| Restored state | Both model/effort profiles runtime default, both providers selected, durable enabled=false, history length 0 |

No actual slot/model request was sent. The app was left open with scheduling OFF. Screenshots and detailed local logs are retained as private evidence; personal registry/project names are not published here.

### Installed CLI / environment

- Installed provider versions used in this check: Codex 0.139.0 / Claude Code 2.1.118. These are a dated validation snapshot, not minimum/latest-version promises.
- Installed AIB v1.4.0 smoke: version, isolated HOME/registry/settings init, documented `sync --dry-run <path>` with unchanged fixture file hashes, native hook definition installation. No project trust or global provider-setting changes.
- On macOS 27 / Homebrew 5.1.15 / CLT 26.5, local Homebrew installation was blocked by missing dependency bottles/CLT 27 requirements; old-formula removal also returned `:dunno`. A SHA256-verified official v1.4.0 archive plus the existing system jq was manually installed instead; the old Homebrew keg was preserved unlinked.
- **Supported-macOS Homebrew install/test CI and this local manual installation are separate evidence.** No Xcode/CLT or provider CLI upgrade, security-warning bypass, or existing barrack-template synchronization was performed.
- See [CLI installation and rollback guidance](https://github.com/ai-barracks/ai-barracks/blob/main/docs/installation.md).

## Explicit limits
Actual scheduled-slot transmission, subscription/model-response E2E, task-level model quality eval and full PTY/IME E2E were not performed; development/tests send no model prompts. The native UI smoke above is not evidence of live-model execution. Application/OS sleep, quit and reboot are not wake-up mechanisms; missed slots are skipped. Usage-window reset/free requests are not guaranteed; account credits/extra usage may bill, and provider-internal transport retries cannot be controlled by this scheduler.

Authentication output, tokens and raw model responses are not persisted by the activation feature. Corrupt/unknown state, API authentication and unsupported CLI behavior fail closed. OFF cancels current work even on save failure, but durable OFF must be confirmed after repairing storage before restarting.

The Mach-O executable is linker-signed ad-hoc, with Info.plist unbound and resources unsealed. The whole app bundle does not have Apple Developer signing/notarization; assets must not be described as Apple-notarized. Archive checksum verification is not notarization. No OS security warning was bypassed and no Gatekeeper/quarantine protection was disabled during the check.
