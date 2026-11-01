import AppKit

/// M3 in the real window: ⌘N grows the preset and focuses the new pane;
/// ⌘⇧A finds the pane that runs an agent by process tree. Uses the
/// "터미널" client so no real agent starts.
@MainActor
struct AgentSuite {
    let harness: SelfTestHarness

    func run() async -> [TestResult] {
        [await launchGrowsAndFocuses(), await shortcutReachesMenu(), await matchesPaneByProcess()]
    }

    private func launchGrowsAndFocuses() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        guard let first = harness.makeRecorderPane(name: "agent-base") else {
            return .make("AG-01b", "⌘N 시작", status: .fail, cause: .app, evidence: ["reason": "setup"], startedAt: start)
        }
        await harness.install([first.pane], layout: .single)
        let launched = workspace.launchAgent(.terminal, skipPermissions: false)
        let attached = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) {
            launched?.probeView?.window != nil && launched?.processID != nil
        }
        let focused = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { harness.isFirstResponder(launched?.probeView) }
        let ok = attached && focused && workspace.layout == .double && workspace.panes.count == 2
            && workspace.destination == .sessions
        return .make("AG-01b", "⌘N: 1분할 → 2분할로 늘려 새 pane 시작·포커스",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["layout": "\(workspace.layout)", "panes": "\(workspace.panes.count)",
                                "attached": "\(attached)", "focused": "\(focused)"], startedAt: start)
    }

    /// ⌘N typed in a focused terminal must open the sheet, not reach
    /// Ghostty's own keybind (cf. ⌥⌘I, IN-11b) nor the PTY.
    private func shortcutReachesMenu() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        guard let recorder = harness.makeRecorderPane(name: "agent-shortcut"), let window = harness.window,
              let key = EventSynthesizer.key("n", modifiers: .command)
        else { return .make("AG-01c", "⌘N", status: .fail, cause: .app, evidence: ["reason": "setup"], startedAt: start) }
        await harness.install([recorder.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorder.log.isReady }
        harness.focus(recorder.pane)
        let mark = recorder.log.mark()
        EventSynthesizer.press(key, in: window)
        let opened = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { workspace.isNewAgentSheetPresented }
        let leaked = await harness.settledBytes(recorder.log, since: mark, expectingAtLeast: 0)
        workspace.isNewAgentSheetPresented = false
        await harness.pause(.milliseconds(400))
        return .make("AG-01c", "터미널 포커스에서 ⌘N → 시작 시트(PTY로 새지 않음)",
                     status: opened && leaked.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["sheet": "\(opened)", "leaked": Hex.string(leaked)], startedAt: start)
    }

    private func matchesPaneByProcess() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        guard let barrack = workspace.selectedBarrackID, let a = harness.makeRecorderPane(name: "match-a"),
              let b = harness.makeRecorderPane(name: "match-b")
        else { return .make("AT-01c", "pane 매칭", status: .fail, cause: .app, evidence: ["reason": "setup"], startedAt: start) }
        await harness.install([a.pane, b.pane], layout: .double)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { a.pane.processID != nil && b.pane.processID != nil }
        let session = LiveSession(id: "t", state: .blocked, ageSeconds: 0, pid: b.pane.processID ?? 0, cwd: nil)
        let matched = workspace.pane(running: session, in: barrack)
        let none = workspace.pane(running: LiveSession(id: "x", state: .blocked, ageSeconds: 0, pid: 1, cwd: nil), in: barrack)
        let ok = matched?.id == b.pane.id && none == nil
        return .make("AT-01c", "⌘⇧A: 에이전트 pid를 가진 pane을 찾음(다른 pane·무관 pid는 아님)",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["matched": matched?.title ?? "nil", "unrelated": none?.title ?? "nil"], startedAt: start)
    }
}
