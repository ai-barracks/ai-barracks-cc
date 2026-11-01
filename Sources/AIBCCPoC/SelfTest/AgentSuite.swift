import AppKit

/// M3 in the real window: ⌘N grows the preset and focuses the new pane;
/// ⌘⇧A finds the pane that runs an agent by process tree. Uses the
/// "터미널" client so no real agent starts.
@MainActor
struct AgentSuite {
    let harness: SelfTestHarness

    func run() async -> [TestResult] {
        [await launchGrowsAndFocuses(), await shortcutReachesMenu(), await matchesPaneByProcess(),
         await maintenanceRunsInPane(), await maintenanceScanCompletes(), await destinationRoundTrip()]
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

    /// A 정비 action runs visibly: a new pane, the command, a shell after.
    private func maintenanceRunsInPane() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-mt-\(UUID().uuidString)")
        guard let base = harness.makeRecorderPane(name: "mt-base") else {
            return .make("MT-01b", "정비 실행", status: .fail, cause: .app, evidence: ["reason": "setup"], startedAt: start)
        }
        await harness.install([base.pane], layout: .single)
        let pane = workspace.runInPane(title: "정비", command: "echo done > \(AgentLauncher.shellQuote(marker.path))")
        let ran = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) {
            FileManager.default.fileExists(atPath: marker.path)
        }
        try? FileManager.default.removeItem(at: marker)
        let ok = ran && pane != nil && workspace.panes.count == 2
        return .make("MT-01b", "정비 동작은 새 터미널 pane에서 실행(결과가 보임)",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["ran": "\(ran)", "panes": "\(workspace.panes.count)"], startedAt: start)
    }

    /// The read-only scan against the real aib finishes.
    private func maintenanceScanCompletes() async -> TestResult {
        let start = ContinuousClock.now
        let store = harness.workspace.maintenance
        await store.scan(harness.workspace.selectedBarrack)
        let elapsed = (ContinuousClock.now - start).milliseconds
        return .make("MT-01c", "정비 점검(aib dry-run·verify·lint)이 끝나고 항목을 냄",
                     status: !store.isScanning && elapsed < 30_000 ? .pass : .fail, cause: .app,
                     evidence: ["items": store.items.map { "\($0.kind.rawValue)=\($0.count)" }.joined(separator: ","),
                                "ms": String(format: "%.0f", elapsed)], startedAt: start)
    }

    /// P0 across destinations: Git/Skills replace the terminals on screen;
    /// coming back shows the same shell, which still takes input.
    private func destinationRoundTrip() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        guard let recorder = harness.makeRecorderPane(name: "dest"), let window = harness.window else {
            return .make("DS-01a", "목적지 왕복", status: .fail, cause: .app, evidence: ["reason": "setup"], startedAt: start)
        }
        await harness.install([recorder.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorder.log.isReady }
        let pid = recorder.pane.processID
        for destination in [Destination.git, .skills, .council, .rules] {
            workspace.destination = destination
            await harness.pause(.milliseconds(400))
        }
        let detached = recorder.pane.probeView?.window == nil
        workspace.destination = .sessions
        let back = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { recorder.pane.probeView?.window != nil }
        await harness.click(row: 2, column: 2, in: recorder.pane)
        let mark = recorder.log.mark()
        EventSynthesizer.type("ok", in: window)
        let typed = await harness.settledBytes(recorder.log, since: mark, expectingAtLeast: 2)
        let ok = detached && back && recorder.pane.processID == pid && typed == Hex.bytes("ok")
        return .make("DS-01a", "Git·Skills·Council·규칙을 거쳐 돌아와도 같은 셸·입력 정상",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["detached_while_away": "\(detached)", "reattached": "\(back)",
                                "same_process": "\(recorder.pane.processID == pid)", "typed": Hex.string(typed)],
                     startedAt: start)
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
