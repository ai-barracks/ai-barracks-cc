import Foundation

/// "정리하고 닫기" (2026-11-24). Measured: X hangs up the agent, and aib's
/// hooks still close the record (row, Status, Ended, seal) — but the barrack
/// protocol's Growth Audit (wiki, RULES.md, Wiki Extractions) is the agent's
/// own work and needs a turn it never gets. This types the wrap-up request,
/// then closes the terminal once that turn finished: as aib reports it, or,
/// for a Codex without aib's hooks, as Codex's own transcript records it.
struct WrapUp: Equatable, Sendable {
    /// What tells the app the wrap-up's turn ended.
    enum Tracker: Equatable, Sendable {
        /// aib liveness (Claude; Codex with `aib hooks codex install`).
        case aib
        /// Codex's own transcript.
        case codexTranscript(CodexWatch)
    }

    /// Where a Codex without aib hooks will record the wrap-up's turn.
    struct CodexWatch: Equatable, Sendable {
        /// Each transcript's size at the request: only what follows is read
        /// (a transcript new since then, from its start).
        let offsets: [String: UInt64]
        /// Those the terminal's own processes held then: its Codex's.
        let owned: [String]
        /// The folder the terminal's Codex runs in. Any other transcript
        /// (a background server's) counts only for a turn run there.
        let cwd: String?
        let home: String
    }

    let paneID: UUID
    let barrackID: Barrack.ID
    let requestedAt: Date
    var tracker: Tracker = .aib
}

enum WrapUpRule {
    enum Decision: Equatable { case wait, close, forget, expire, failed, notFound }

    /// aib keeps one run_id for a whole session, so the wrap-up's turn is a
    /// finish (`done`, or `idle` once seen) written after the request, left
    /// to stand a moment for the turn's other Stop hooks. A SessionStart
    /// after the request is a compaction inside the turn: it folds to idle
    /// but nothing finished.
    static func decide(_ wrapUp: WrapUp, session: LiveSession?, paneGone: Bool, now: Date) -> Decision {
        if paneGone { return .forget }
        if let session, session.state == .done || session.state == .idle, session.event != "SessionStart",
           session.updatedAt > Int(wrapUp.requestedAt.timeIntervalSince1970) {
            let standing = Int(now.timeIntervalSince1970) - session.updatedAt
            return standing >= AppConstants.WrapUp.settleSeconds ? .close : .wait
        }
        return now.timeIntervalSince(wrapUp.requestedAt) > AppConstants.WrapUp.timeout ? .expire : .wait
    }

    /// Codex without aib hooks: the turn its transcript holds the request in.
    static func decide(_ wrapUp: WrapUp, codex turn: CodexTranscript.Turn, paneGone: Bool, now: Date) -> Decision {
        if paneGone { return .forget }
        let waited = now.timeIntervalSince(wrapUp.requestedAt)
        switch turn {
        case let .finished(at):
            return now.timeIntervalSince(at) >= TimeInterval(AppConstants.WrapUp.settleSeconds) ? .close : .wait
        case .failed:
            return .failed
        case .notYet:
            return waited > AppConstants.WrapUp.codexNotSeenTimeout ? .notFound : .wait
        case .running:
            return waited > AppConstants.WrapUp.timeout ? .expire : .wait
        }
    }
}

extension LiveSession {
    /// Mid-reply. An agent that has had no turn yet folds to idle, not
    /// working (the real-agent run read SessionStart's `working` there).
    var isMidTurn: Bool { state == .working }
}

extension WorkspaceModel {
    enum WrapUpOutcome: Equatable {
        /// Typed; the terminal closes when the turn finishes.
        case started
        /// Typed, but nothing reports this agent's turns (no aib state, not
        /// Codex): it stays open.
        case sentWithoutClose
        /// Nothing typed: not an agent, mid-turn, or waiting for the user.
        case refused
        /// Asked again while pending: it will not close.
        case cancelled
    }

    /// The aib session running in `pane`, if any.
    func liveSession(of pane: TerminalPane) -> LiveSession? {
        selectedBarrackID.flatMap { liveSession(of: pane, in: $0) }
    }

    func liveSession(of pane: TerminalPane, in barrack: Barrack.ID) -> LiveSession? {
        liveness.sessions(of: barrack).first { self.pane(running: $0, in: barrack)?.id == pane.id }
    }

    /// What the agent in `pane` is doing (aib liveness), if one runs there.
    func liveness(of pane: TerminalPane) -> Liveness? {
        liveSession(of: pane)?.state
    }

    /// The ⌘⇧W target: the terminal with keyboard focus, else the one last
    /// focused; with a single slot, the one on screen.
    var wrapUpTarget: TerminalPane? {
        if let slot = focusedSlot, slot < panes.count { return panes[slot] }
        return layout.paneCount == 1 ? panes.first : nil
    }

    /// ⌘⇧W: start a wrap-up, or call off the close of a pending one.
    @discardableResult
    func toggleWrapUp(of pane: TerminalPane?) -> WrapUpOutcome {
        guard let pane else {
            notifyWrapUp("정리할 터미널을 고르세요", "닫을 에이전트 터미널을 클릭한 뒤 ⌘⇧W를 누르세요.")
            return .refused
        }
        guard wrapUps[pane.id] == nil else {
            wrapUps = wrapUps.filter { $0.key != pane.id }
            notifyWrapUp("닫지 않습니다", "\(pane.title): 정리 요청은 이미 보냈고, 끝나도 터미널은 그대로 둡니다.")
            return .cancelled
        }
        return startWrapUp(of: pane)
    }

    /// `current`: the agent's aib state now; `transcripts`: the Codex
    /// transcripts the pane holds open; `codexHome`: where Codex files
    /// them (tests pass these; nil reads them).
    @discardableResult
    func startWrapUp(of pane: TerminalPane, current: LiveSession?? = nil, transcripts: [URL]? = nil,
                     codexHome: URL? = nil) -> WrapUpOutcome {
        guard let barrack = selectedBarrackID, panes.contains(where: { $0.id == pane.id }), !pane.hasExited else {
            return .refused
        }
        let session = current ?? liveSession(of: pane, in: barrack)
        guard pane.agent != nil || session != nil else {
            notifyWrapUp("에이전트 터미널이 아닙니다", "\(pane.title)에는 정리 요청을 보내지 않습니다. 셸은 X로 닫으세요.")
            return .refused
        }
        let owned = session == nil && pane.agent == .codex
            ? transcripts ?? CodexTranscript.openTranscripts(under: pane.processID) : nil
        let busy = session.map { $0.isMidTurn || $0.state == .blocked } ?? owned?.contains(where: CodexTranscript.isMidTurn(at:)) ?? false
        if busy {
            let waiting = session?.state == .blocked
            notifyWrapUp(waiting ? "입력을 기다리는 중입니다" : "작업 중입니다",
                         "\(pane.title): 지금 턴이 끝난 뒤 다시 누르세요. 아무것도 입력하지 않았습니다.")
            return .refused
        }
        let tracker: WrapUp.Tracker? = session != nil ? .aib : owned.map { owned in
            let home = codexHome ?? CodexTranscript.home
            return WrapUp.Tracker.codexTranscript(WrapUp.CodexWatch(
                offsets: CodexTranscript.sizes(owned + CodexTranscript.recentTranscripts(in: home)), owned: owned.map(CodexTranscript.canonical),
                cwd: pane.workingDirectory ?? selectedBarrack?.path, home: home.path))
        }
        guard type(AppConstants.WrapUp.request(closing: tracker != nil), into: pane) else { return .refused }
        guard let tracker else {
            notifyWrapUp("정리 요청을 보냈습니다", "\(pane.title): 이 에이전트의 턴 끝을 알 수 없어(aib 상태 없음) 끝나도 닫지 않습니다. 정리가 끝나면 X로 닫으세요.")
            return .sentWithoutClose
        }
        let wrapUp = WrapUp(paneID: pane.id, barrackID: barrack, requestedAt: Date(), tracker: tracker)
        wrapUps = wrapUps.merging([pane.id: wrapUp]) { _, new in new }
        watchWrapUps()
        return .started
    }

    /// Applies each pending wrap-up's decision. `lookup` and `codexLookup`
    /// stand in for aib and Codex's transcript in tests.
    func checkWrapUps(now: Date = Date(), lookup: ((WrapUp) -> LiveSession?)? = nil,
                      codexLookup: ((WrapUp) -> CodexTranscript.Turn)? = nil) {
        let decisions = wrapUps.values.map { wrapUp -> (WrapUp, TerminalPane?, WrapUpRule.Decision) in
            let pane = grids[wrapUp.barrackID]?.panes.first { $0.id == wrapUp.paneID }
            let gone = pane?.hasExited ?? true
            switch wrapUp.tracker {
            case .aib:
                let session = lookup.map { $0(wrapUp) } ?? pane.flatMap { liveSession(of: $0, in: wrapUp.barrackID) }
                return (wrapUp, pane, WrapUpRule.decide(wrapUp, session: session, paneGone: gone, now: now))
            case let .codexTranscript(watch):
                let turn = codexLookup.map { $0(wrapUp) } ?? pane.map { codexTurn(in: $0, watch: watch, since: wrapUp.requestedAt) }
                return (wrapUp, pane, WrapUpRule.decide(wrapUp, codex: turn ?? .notYet, paneGone: gone, now: now))
            }
        }
        let settled = Set(decisions.filter { $0.2 != .wait }.map(\.0.paneID))
        wrapUps = wrapUps.filter { !settled.contains($0.key) }
        for (wrapUp, pane, decision) in decisions {
            let title = pane?.title ?? "터미널"
            switch decision {
            case .close: closePane(id: wrapUp.paneID, inBarrack: wrapUp.barrackID)
            case .expire: notifyWrapUp("정리가 끝나지 않아 닫지 않았습니다", "\(title): 30분 안에 턴이 끝나지 않았습니다. 터미널을 확인하세요.")
            case .failed: notifyWrapUp("정리 턴이 멈춰 닫지 않았습니다", "\(title): Codex가 오류로 멈췄거나 중단됐습니다. 터미널을 확인하세요.")
            case .notFound: notifyWrapUp("정리 요청이 보이지 않아 닫지 않습니다", "\(title): Codex 기록에 정리 요청이 없습니다. 정리가 끝나면 X로 닫으세요.")
            case .wait, .forget: break
            }
        }
    }

    /// The request's turn: in the transcripts the terminal holds now or held
    /// at the request (a Codex that quit closed its file), else in any
    /// other recent one, for a turn in the terminal's folder.
    private func codexTurn(in pane: TerminalPane, watch: WrapUp.CodexWatch, since: Date) -> CodexTranscript.Turn {
        let owned = Set(CodexTranscript.openTranscripts(under: pane.processID).map(\.path) + watch.owned)
        let fresh = CodexTranscript.transcripts(startedAround: since, in: URL(fileURLWithPath: watch.home)).map(\.path)
        let others = Set(watch.offsets.keys).union(fresh).subtracting(owned)
        let urls = { (paths: Set<String>) in paths.sorted().map { URL(fileURLWithPath: $0) } }
        return CodexTranscript.turn(of: AppConstants.WrapUp.requestBody, since: since, owned: urls(owned), others: urls(others),
                                    offsets: watch.offsets, cwd: watch.cwd)
    }

    /// Text first, Enter a moment later as its own keystroke (Codex reads
    /// an Enter inside a fast burst as a pasted newline).
    private func type(_ text: String, into pane: TerminalPane) -> Bool {
        guard pane.state.performBindingAction(GhosttyText.action(typing: text, pressEnter: false)) else { return false }
        Task { @MainActor in
            try? await Task.sleep(for: AppConstants.WrapUp.submitDelay)
            _ = pane.state.performBindingAction(GhosttyText.action(typing: "", pressEnter: true))
        }
        return true
    }

    private func watchWrapUps() {
        guard wrapUpWatch == nil else { return }
        wrapUpWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled, let model = self, !model.wrapUps.isEmpty {
                try? await Task.sleep(for: .seconds(AppConstants.Liveness.refreshInterval))
                model.checkWrapUps()
            }
            self?.wrapUpWatch = nil
        }
    }

    private func notifyWrapUp(_ title: String, _ body: String) {
        notices.post(AppNotice(kind: .panes, title: title, body: body, actionLabel: nil,
                               barrackID: selectedBarrack?.id, sessionID: nil))
    }
}
