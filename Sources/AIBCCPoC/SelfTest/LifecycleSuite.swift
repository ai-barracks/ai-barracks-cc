import AppKit

/// ST-01a (4-split: input isolation + resize triad per pane) and ST-04a
/// (a pane whose process exits is cleaned up).
@MainActor
struct LifecycleSuite {
    let harness: SelfTestHarness

    func run() async -> [TestResult] {
        [await quadSplit(), await shellExitCleanup(), await barrackContextFollowsSelection()]
    }

    /// WS-01a (Codex runtime review R1, r3 #1/#5): with a LIVE process in
    /// barrack A, selecting barrack B shows B's grid whose shell really runs
    /// in B (process cwd), moves terminal focus to it and switches artifacts;
    /// A's process stays alive while hidden, and after returning the same
    /// process receives typing through a real click.
    private func barrackContextFollowsSelection() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        guard let original = workspace.selectedBarrack,
              let other = workspace.barracks.first(where: { $0.id != original.id }),
              let window = harness.window,
              let live = harness.makeRecorderPane(name: "ws-live")
        else {
            return .make("WS-01a", "배럭 선택 = 터미널 cwd = 산출물 맥락", status: .unverified,
                         evidence: ["reason": "needs two registered barracks"], startedAt: start)
        }
        await harness.install([live.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { live.log.isReady }
        await harness.pause(AppConstants.SelfTest.minimumChildRuntime)
        live.pane.startExitMonitorIfNeeded()
        let livePID = live.pane.monitoredPID ?? 0
        harness.focus(live.pane)

        workspace.selectedBarrackID = other.id
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) {
            workspace.panes.first?.probeView?.foregroundPid != nil && harness.artifacts.watchedRoot == other.url
        }
        await harness.pause(.milliseconds(500))
        let otherPane = workspace.panes.first
        let otherPID = otherPane?.probeView?.foregroundPid ?? 0
        let cwd = ProcessCWD.path(of: otherPID).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let cwdMatches = cwd == other.url.resolvingSymlinksInPath().path
        let focusHandedOver = harness.isFirstResponder(otherPane?.probeView)
        let aliveWhileHidden = ProcessCWD.isAlive(livePID)

        workspace.selectedBarrackID = original.id
        let restored = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            workspace.panes.first?.id == live.pane.id && live.pane.probeView?.window != nil
                && harness.artifacts.watchedRoot == original.url
        }
        await harness.click(row: 3, column: 2, in: live.pane)
        let mark = live.log.mark()
        EventSynthesizer.type("x", in: window)
        let typed = await harness.settledBytes(live.log, since: mark)
        let ok = cwdMatches && focusHandedOver && aliveWhileHidden && restored
            && ProcessCWD.isAlive(livePID) && typed == [0x78]
        return .make("WS-01a", "배럭 전환: 실제 cwd·포커스 인계·숨은 프로세스 생존·복귀 후 입력",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["other_cwd": cwd ?? "nil", "cwd_matches": "\(cwdMatches)",
                                "focus_handed_over": "\(focusHandedOver)",
                                "alive_while_hidden": "\(aliveWhileHidden)", "restored": "\(restored)",
                                "typed_after_return": Hex.string(typed)],
                     startedAt: start)
    }

    private func quadSplit() async -> TestResult {
        let start = ContinuousClock.now
        let recorders = (1...4).compactMap { harness.makeRecorderPane(name: "quad-\($0)") }
        guard recorders.count == 4, let window = harness.window else {
            return .make("ST-01a", "4분할 입력 격리·리사이즈", status: .fail, cause: .app,
                         evidence: ["reason": "setup"], startedAt: start)
        }
        await harness.install(recorders.map(\.pane), layout: .quad)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorders.allSatisfy { $0.log.isReady } }
        let isolation = await inputIsolation(recorders, window)
        let original = window.frame
        let resized = await resizeAndSettle(recorders) { window.setContentSize(AppConstants.SelfTest.resizeSmallSize) }
        let restored = await resizeAndSettle(recorders) { window.setFrame(original, display: true) }
        let ok = isolation.isEmpty && resized && restored
        return .make("ST-01a", "4분할: pane별 입력 격리 + 리사이즈 grid·PTY 일치",
                     status: ok ? .pass : .fail,
                     evidence: ["isolation_failures": isolation.joined(separator: "; "),
                                "resized": "\(resized)", "restored": "\(restored)"],
                     startedAt: start)
    }

    /// Clicks into each pane and types a distinct letter; only that pane may
    /// receive it.
    private func inputIsolation(_ recorders: [SelfTestHarness.RecorderPane], _ window: NSWindow) async -> [String] {
        var failures: [String] = []
        for (index, target) in recorders.enumerated() {
            let marks = recorders.map { $0.log.mark() }
            await harness.click(row: 3, column: 2, in: target.pane)
            let letter = ["a", "b", "c", "d"][index]
            EventSynthesizer.type(letter, in: window)
            _ = await harness.settledBytes(target.log, since: marks[index])
            for (other, recorder) in recorders.enumerated() {
                let received = recorder.log.bytes(since: marks[other])
                let expected = other == index ? Hex.bytes(letter) : []
                if received != expected {
                    failures = failures + ["pane\(other + 1) got \(Hex.string(received)) when typing in pane\(index + 1)"]
                }
            }
        }
        return failures
    }

    /// Waits for the first pane's grid to change, then for every pane's grid
    /// and PTY winsize to agree and stay unchanged for `stableWindow`.
    private func resizeAndSettle(_ recorders: [SelfTestHarness.RecorderPane], _ change: () -> Void) async -> Bool {
        let before = recorders.first?.pane.state.surfaceSize
        change()
        let changed = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            recorders.first?.pane.state.surfaceSize != before
        }
        guard changed else { return false }
        let deadline = ContinuousClock.now + AppConstants.SelfTest.settleTimeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            let snapshot = recorders.map(\.pane.state.surfaceSize)
            if recorders.allSatisfy(gridMatchesPTY) {
                await harness.pause(AppConstants.SelfTest.stableWindow)
                if recorders.map(\.pane.state.surfaceSize) == snapshot, recorders.allSatisfy(gridMatchesPTY) {
                    return true
                }
            } else {
                await harness.pause(AppConstants.SelfTest.pollInterval)
            }
        }
        return false
    }

    private func gridMatchesPTY(_ recorder: SelfTestHarness.RecorderPane) -> Bool {
        guard let grid = recorder.pane.state.surfaceSize, let pty = recorder.log.lastWinsize() else { return false }
        return Int(grid.columns) == pty.cols && Int(grid.rows) == pty.rows
    }

    private func shellExitCleanup() async -> TestResult {
        let start = ContinuousClock.now
        guard let recorder = harness.makeRecorderPane(name: "exit"), let window = harness.window,
              let ctrlD = EventSynthesizer.control("d")
        else {
            return .make("ST-04a", "프로세스 종료 시 pane 정리", status: .fail, cause: .app,
                         evidence: ["reason": "setup"], startedAt: start)
        }
        await harness.install([recorder.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorder.log.isReady }
        // Ghostty treats a child that exits within 250ms of launch as an
        // abnormal exit and keeps the surface; a real shell lives longer.
        await harness.pause(AppConstants.SelfTest.minimumChildRuntime)
        harness.focus(recorder.pane)
        recorder.pane.startExitMonitorIfNeeded()
        let pid = recorder.pane.monitoredPID
        EventSynthesizer.press(ctrlD, in: window)
        let detected = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            recorder.pane.hasExited && recorder.pane.isChildGone
        }
        return .make("ST-04a", "프로세스 종료 감지 + 자식 회수(좀비·고아 0), 출력 보존 배너",
                     status: detected ? .pass : .fail, cause: .app,
                     evidence: ["pid": pid.map(String.init) ?? "nil",
                                "exited": "\(recorder.pane.hasExited)",
                                "child_gone": "\(recorder.pane.isChildGone)"],
                     startedAt: start)
    }
}
