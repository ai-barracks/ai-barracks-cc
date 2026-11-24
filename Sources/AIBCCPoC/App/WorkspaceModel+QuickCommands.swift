import Foundation

/// A Quick Command waiting for the user (Codex parity audit P03).
enum QuickCommandPrompt: Identifiable {
    /// The saved folder is gone: fix it, run once in the barrack, or cancel.
    case missingFolder(QuickCommand)
    /// Typing into a terminal; `program` is what it ran when asked.
    case confirmSend(QuickCommand, TerminalPane, ForegroundProgram?)

    var id: String {
        switch self {
        case let .missingFolder(quick): "folder-\(quick.id)"
        case let .confirmSend(quick, pane, _): "send-\(quick.id)-\(pane.id)"
        }
    }
}

/// Quick Commands as in v1: running one opens a new terminal in its folder
/// (or the barrack's) — never types into whatever has focus, which may be
/// Claude or Codex reading it as a prompt. Typing into an existing terminal
/// is a separate action that always asks, refuses agents, and is checked
/// again at the moment it would type (Codex review of P03: a yes given
/// earlier, or a pending "leave the edit?", must not carry a command into
/// an agent that started meanwhile).
extension WorkspaceModel {
    enum SendOutcome: Equatable {
        case sent, refused, needsConfirmation, failed
    }

    /// An open edit is left first; the folder is checked after that, at
    /// the moment the terminal is made.
    @discardableResult
    func run(_ quick: QuickCommand) -> TerminalPane? {
        guard !editInProgress else {
            navigate { [weak self] in _ = self?.run(quick) }
            return nil
        }
        if let folder = quick.cwd, !Self.isDirectory(folder) {
            quickCommandPrompt = .missingFolder(quick)
            return nil
        }
        return launch(quick, in: quick.cwd)
    }

    /// The saved folder is gone: this once, in the barrack's folder.
    @discardableResult
    func runInBarrackFolder(_ quick: QuickCommand) -> TerminalPane? {
        guard !editInProgress else {
            navigate { [weak self] in _ = self?.runInBarrackFolder(quick) }
            return nil
        }
        return launch(quick, in: nil)
    }

    /// "경로 수정": the sheet opens once the alert has closed (a sheet asked
    /// for while an alert is closing is dropped).
    func editAfterAlert(_ quick: QuickCommand) {
        DispatchQueue.main.asyncAfter(deadline: .now() + AppConstants.Layout.presentAfterAlert) { [weak self] in
            self?.quickCommandDraft = quick
        }
    }

    /// Asks before typing into an existing terminal; agents are refused.
    @discardableResult
    func send(_ quick: QuickCommand, to pane: TerminalPane) -> SendOutcome {
        if let refusal = refusal(of: pane) { return refusal }
        quickCommandPrompt = .confirmSend(quick, pane, ProcessTree.foreground(of: pane.processID))
        return .needsConfirmation
    }

    /// The yes: still refused for an agent, a closed or moved terminal, or
    /// a foreground program other than the one the user saw.
    @discardableResult
    func confirmSend(_ quick: QuickCommand, to pane: TerminalPane, program: ForegroundProgram?) -> SendOutcome {
        guard !editInProgress else {
            navigate { [weak self] in _ = self?.confirmSend(quick, to: pane, program: program) }
            return .needsConfirmation
        }
        if let refusal = refusal(of: pane) { return refusal }
        guard ProcessTree.foreground(of: pane.processID) == program else {
            notify("입력하지 않았습니다", "\(pane.title)에서 실행 중인 프로그램이 확인 뒤에 바뀌었습니다.")
            return .refused
        }
        destination = .sessions
        focusWhenAttached(pane)
        return pane.state.performBindingAction(GhosttyText.action(typing: quick.command, pressEnter: true)) ? .sent : .failed
    }

    func isAgent(_ pane: TerminalPane) -> Bool {
        pane.agent != nil || liveness(of: pane) != nil
    }

    /// Save needs a known launch: a reattached pane whose start was not
    /// recorded has no folder, and posing the barrack's would mislead.
    func canSaveDraft(from pane: TerminalPane) -> Bool {
        pane.workingDirectory != nil
    }

    /// "Quick Command로 저장" (v1 Save): the terminal's name, the command it
    /// started with and its folder, ready to edit.
    func saveDraft(from pane: TerminalPane) {
        guard canSaveDraft(from: pane) else { return }
        quickCommandDraft = QuickCommand(label: pane.title, command: pane.userCommand ?? "", cwd: pane.workingDirectory)
    }

    private func refusal(of pane: TerminalPane) -> SendOutcome? {
        if isAgent(pane) {
            notify("에이전트 터미널에는 보내지 않습니다", "\(pane.title)에 입력하면 모델 프롬프트가 됩니다. Quick Command 실행은 새 터미널에서 합니다.")
            return .refused
        }
        guard panes.contains(where: { $0.id == pane.id }), !pane.hasExited else { return .failed }
        return nil
    }

    private func notify(_ title: String, _ body: String) {
        notices.post(AppNotice(kind: .panes, title: title, body: body, actionLabel: nil,
                               barrackID: selectedBarrack?.id, sessionID: nil))
    }

    /// An interactive login shell, so aliases from .zshrc work as when v1
    /// typed the command into a new shell; the shell stays afterwards. A
    /// newline, not "; ", ends the command: "printf ok;" stays valid.
    private func launch(_ quick: QuickCommand, in folder: String?) -> TerminalPane? {
        let program = quick.command + "\nexec /bin/zsh -l"
        return openPane(title: quick.label, command: "/bin/zsh -lic " + AgentLauncher.shellQuote(program),
                        directory: folder, userCommand: quick.command)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
