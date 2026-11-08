import Foundation

/// A Quick Command waiting for the user (Codex parity audit P03).
enum QuickCommandPrompt: Identifiable {
    /// The saved folder is gone: fix it, run once in the barrack, or cancel.
    case missingFolder(QuickCommand)
    /// Typing into a terminal whose foreground program is not known.
    case confirmSend(QuickCommand, TerminalPane)

    var id: String {
        switch self {
        case let .missingFolder(quick): "folder-\(quick.id)"
        case let .confirmSend(quick, pane): "send-\(quick.id)-\(pane.id)"
        }
    }
}

/// Quick Commands as in v1: running one opens a new terminal in its folder
/// (or the barrack's) — never types into whatever has focus, which may be
/// Claude or Codex reading it as a prompt. Typing into an existing terminal
/// is a separate action that refuses agents and asks unless the terminal
/// is an idle shell.
extension WorkspaceModel {
    enum SendOutcome: Equatable {
        case sent, refused, needsConfirmation, failed
    }

    @discardableResult
    func run(_ quick: QuickCommand) -> TerminalPane? {
        if let folder = quick.cwd, !Self.isDirectory(folder) {
            quickCommandPrompt = .missingFolder(quick)
            return nil
        }
        return launch(quick, in: quick.cwd)
    }

    /// The saved folder is gone: this once, in the barrack's folder.
    @discardableResult
    func runInBarrackFolder(_ quick: QuickCommand) -> TerminalPane? {
        launch(quick, in: nil)
    }

    @discardableResult
    func send(_ quick: QuickCommand, to pane: TerminalPane) -> SendOutcome {
        if isAgent(pane) {
            notices.post(AppNotice(kind: .panes, title: "에이전트 터미널에는 보내지 않습니다",
                                   body: "\(pane.title)에 입력하면 모델 프롬프트가 됩니다. Quick Command 실행은 새 터미널에서 합니다.",
                                   actionLabel: nil, barrackID: selectedBarrack?.id, sessionID: nil))
            return .refused
        }
        guard pane.isIdleShell else {
            quickCommandPrompt = .confirmSend(quick, pane)
            return .needsConfirmation
        }
        return type(quick, into: pane) ? .sent : .failed
    }

    func isAgent(_ pane: TerminalPane) -> Bool {
        pane.agent != nil || liveness(of: pane) != nil
    }

    /// "Quick Command로 저장" (v1 Save): the terminal's name, the command it
    /// started with and its folder, ready to edit.
    func saveDraft(from pane: TerminalPane) {
        quickCommandDraft = QuickCommand(label: pane.title, command: pane.userCommand ?? "", cwd: pane.workingDirectory)
    }

    /// An interactive login shell, so aliases from .zshrc work as when v1
    /// typed the command into a new shell; the shell stays afterwards.
    private func launch(_ quick: QuickCommand, in folder: String?) -> TerminalPane? {
        let shell = "/bin/zsh -lic " + AgentLauncher.shellQuote(quick.command + "; exec /bin/zsh -l")
        return openPane(title: quick.label, command: shell, directory: folder, userCommand: quick.command)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
