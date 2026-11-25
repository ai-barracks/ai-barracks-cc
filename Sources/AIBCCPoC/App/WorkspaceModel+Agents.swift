import Foundation

extension WorkspaceModel {
    /// ⌘N: a new pane running `aib start <client>` in the selected barrack.
    /// It takes an empty slot or the focused one; the layout stays as set.
    /// A missing claude/codex is offered for install by aib in the pane.
    @discardableResult
    func launchAgent(_ client: AgentClient, skipPermissions: Bool) -> TerminalPane? {
        guard AgentClient.launchable.contains(client) else { return nil }
        let profile = ProviderProfiles.load(client)
        let pane = openPane(title: client.label, command: AgentLauncher.command(for: client, skipPermissions: skipPermissions, profile: profile),
                            userCommand: AgentLauncher.start(client, skipPermissions: skipPermissions, profile: profile),
                            agent: client == .terminal ? nil : client)
        if client == .codex, let pane, let barrack = selectedBarrackID { watchCodexHooks(pane, in: barrack) }
        return pane
    }

    /// Codex reports to aib only through hooks it trusts. A Codex pane with
    /// no aib state after a while gets one hint per app run: install them,
    /// or trust them in /hooks (2026-11-25: Codex agents showed no state and
    /// 정리하고 닫기 could not close them).
    private func watchCodexHooks(_ pane: TerminalPane, in barrack: Barrack.ID) {
        guard !CodexHookHint.shown else { return }
        let barrackPath = barracks.first { $0.id == barrack }?.path
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: AppConstants.CodexHooks.hintDelay)
            guard let self, !CodexHookHint.shown, !pane.hasExited, self.liveSession(of: pane, in: barrack) == nil else { return }
            CodexHookHint.shown = true
            let hint = CodexHookHint.message(installed: CodexHookHint.installed(barrackPath: barrackPath))
            self.notices.post(AppNotice(kind: .panes, title: hint.title, body: hint.body, actionLabel: nil,
                                        barrackID: barrack, sessionID: nil))
        }
    }
}

/// What to tell a user whose Codex reports nothing to aib.
enum CodexHookHint {
    @MainActor static var shown = false
    static let command = "aib hook native codex"

    /// aib's handler is in Codex's user hooks, or in the barrack's own.
    static func installed(barrackPath: String?, home: URL = CodexTranscript.home) -> Bool {
        let files = [home.appendingPathComponent("hooks.json")]
            + (barrackPath.map { [URL(fileURLWithPath: $0).appendingPathComponent(".codex/hooks.json")] } ?? [])
        return files.contains { file in
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hooks = json["hooks"] as? [String: Any] else { return false }
            return hooks.values.contains { entries in
                (entries as? [[String: Any]] ?? []).contains { entry in
                    (entry["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
                }
            }
        }
    }

    static func message(installed: Bool) -> (title: String, body: String) {
        installed
            ? ("Codex hook 승인이 필요합니다",
               "Codex가 aib에 상태를 알리지 않습니다. 이 Codex에서 /hooks를 입력하고 '\(command)'를 신뢰하세요(한 번이면 모든 배럭). 그 뒤 새로 띄운 Codex부터 작업 중·완료가 보입니다.")
            : ("Codex hook이 없습니다",
               "Codex가 aib에 상태를 알리지 않습니다. 배럭에서 aib sync(또는 aib hooks codex install --user)로 설치한 뒤, Codex에서 /hooks로 한 번 신뢰하세요.")
    }
}
