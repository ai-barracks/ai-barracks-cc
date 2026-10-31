import AppKit

/// ST-01a (4-split: input isolation + resize triad per pane) and ST-04a
/// (a pane whose process exits is cleaned up).
@MainActor
struct LifecycleSuite {
    let harness: SelfTestHarness

    func run() async -> [TestResult] {
        [await quadSplit(), await shellExitCleanup()]
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
