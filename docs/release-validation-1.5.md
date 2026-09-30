# v1.5.0 release validation

## Goals
1. Runtime-first Codex/Claude model profiles, native interoperability in CLI v1.4 and validated isolated Council results.
2. Default-OFF CommandCenter activation at 06:00 / 11:00 / 16:00 / 21:00 Asia/Seoul: one short request per selected CLI, no application retries or catch-up.

## Acceptance evidence
- CLI: 15 isolated shell regression scripts, including native conversation routing/concurrency/wrapper/trust preservation, skill ownership, structured results/usage and safe profile forwarding.
- Frontend: 101 unit tests and production build.
- Backend: 120 unit tests; Clippy all targets with warnings denied.
- Installed Codex: explicit read-only initialize / initialized / model-list metadata smoke PASS. No thread/turn/model requests.
- npm audit: 0 vulnerabilities after compatible patches. Cargo audit: 0 vulnerabilities; 3 upstream warnings (proc-macro-error/serial unmaintained; glib unsound warning in non-macOS dependency graph).
- Browser mock IPC: activation OFF → confirmation → ON → next KST slot → OFF; no-provider activation rejected.
- Release workflow: regression/security gates, universal macOS package in draft release, publish only after asset inspection.

## Explicit limits
Actual subscription/model-response E2E and task-level model quality eval were not performed; development/tests send no model prompts. macOS UI verification requires an unlocked desktop. Application/OS sleep, quit and reboot are not wake-up mechanisms; missed slots are skipped. Usage-window reset/free requests are not guaranteed; account credits/extra usage may bill, and provider-internal transport retries cannot be controlled by this scheduler.

Authentication output, tokens and raw model responses are not persisted by the activation feature. Corrupt/unknown state, API authentication and unsupported CLI behavior fail closed. OFF cancels current work even on save failure, but durable OFF must be confirmed after repairing storage before restarting.

Existing signing/notarization is not added: release assets must not be described as Apple-notarized. Manual installation may require the existing macOS security workflow.
