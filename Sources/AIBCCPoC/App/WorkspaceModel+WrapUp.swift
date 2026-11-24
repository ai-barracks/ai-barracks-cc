import Foundation

/// "정리하고 닫기" (2026-11-24). Measured: X hangs up the agent, and aib's
/// hooks still close the record (row, Status, Ended, seal) — but the barrack
/// protocol's Growth Audit (wiki, RULES.md, Wiki Extractions) is the agent's
/// own work and needs a turn it never gets. This types the wrap-up request,
/// then closes the terminal once aib reports that turn finished.
struct WrapUp: Equatable, Sendable {
    let paneID: UUID
    let barrackID: Barrack.ID
    let requestedAt: Date
}

enum WrapUpRule {
    enum Decision: Equatable { case wait, close, forget, expire }

    /// aib keeps one run_id for a whole session, so the wrap-up's turn is a
    /// finish (`done`, or `idle` once seen) written after the request, left
    /// to stand a moment for the turn's other Stop hooks.
    static func decide(_ wrapUp: WrapUp, session: LiveSession?, paneGone: Bool, now: Date) -> Decision {
        if paneGone { return .forget }
        if let session, session.state == .done || session.state == .idle,
           session.updatedAt > Int(wrapUp.requestedAt.timeIntervalSince1970) {
            let standing = Int(now.timeIntervalSince1970) - session.updatedAt
            return standing >= AppConstants.WrapUp.settleSeconds ? .close : .wait
        }
        return now.timeIntervalSince(wrapUp.requestedAt) > AppConstants.WrapUp.timeout ? .expire : .wait
    }
}

extension LiveSession {
    /// Mid-reply: `working` from a tool, not the SessionStart of an agent
    /// that has had no turn yet (the real-agent run read `working` there).
    var isMidTurn: Bool { state == .working && event != "SessionStart" }
}

extension WorkspaceModel {
    enum WrapUpOutcome: Equatable {
        /// Typed; the terminal closes when the turn finishes.
        case started
        /// Typed, but aib reports nothing for this agent (Codex without
        /// hooks): it stays open.
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

    /// `current`: the agent's aib state now (tests pass it; nil reads it).
    @discardableResult
    func startWrapUp(of pane: TerminalPane, current: LiveSession?? = nil) -> WrapUpOutcome {
        guard let barrack = selectedBarrackID, panes.contains(where: { $0.id == pane.id }), !pane.hasExited else {
            return .refused
        }
        let session = current ?? liveSession(of: pane, in: barrack)
        guard pane.agent != nil || session != nil else {
            notifyWrapUp("에이전트 터미널이 아닙니다", "\(pane.title)에는 정리 요청을 보내지 않습니다. 셸은 X로 닫으세요.")
            return .refused
        }
        if let session, session.isMidTurn || session.state == .blocked {
            notifyWrapUp(session.isMidTurn ? "작업 중입니다" : "입력을 기다리는 중입니다",
                         "\(pane.title): 지금 턴이 끝난 뒤 다시 누르세요. 아무것도 입력하지 않았습니다.")
            return .refused
        }
        guard type(AppConstants.WrapUp.request, into: pane) else { return .refused }
        guard session != nil else {
            notifyWrapUp("정리 요청을 보냈습니다", "\(pane.title): aib 상태를 알 수 없어(Codex는 `aib hooks codex install` 필요) 끝나도 닫지 않습니다. 정리가 끝나면 X로 닫으세요.")
            return .sentWithoutClose
        }
        wrapUps = wrapUps.merging([pane.id: WrapUp(paneID: pane.id, barrackID: barrack, requestedAt: Date())]) { _, new in new }
        watchWrapUps()
        return .started
    }

    /// Applies each pending wrap-up's decision. `lookup` stands in for aib
    /// in tests.
    func checkWrapUps(now: Date = Date(), lookup: ((WrapUp) -> LiveSession?)? = nil) {
        let decisions = wrapUps.values.map { wrapUp -> (WrapUp, WrapUpRule.Decision) in
            let pane = grids[wrapUp.barrackID]?.panes.first { $0.id == wrapUp.paneID }
            let session = lookup.map { $0(wrapUp) } ?? pane.flatMap { liveSession(of: $0, in: wrapUp.barrackID) }
            return (wrapUp, WrapUpRule.decide(wrapUp, session: session, paneGone: pane?.hasExited ?? true, now: now))
        }
        let settled = Set(decisions.filter { $0.1 != .wait }.map(\.0.paneID))
        wrapUps = wrapUps.filter { !settled.contains($0.key) }
        for (wrapUp, decision) in decisions {
            switch decision {
            case .close: closePane(id: wrapUp.paneID, inBarrack: wrapUp.barrackID)
            case .expire: notifyWrapUp("정리가 끝나지 않아 닫지 않았습니다", "30분 안에 턴이 끝나지 않았습니다. 터미널을 확인하세요.")
            case .wait, .forget: break
            }
        }
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
