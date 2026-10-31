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
        window.setContentSize(AppConstants.SelfTest.resizeSmallSize)
        let resized = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            recorders.allSatisfy(gridMatchesPTY)
        }
        window.setFrame(original, display: true)
        let restored = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            recorders.allSatisfy(gridMatchesPTY)
        }
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
        harness.focus(recorder.pane)
        let exitedID = recorder.pane.id
        EventSynthesizer.press(ctrlD, in: window)
        let replaced = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            !harness.workspace.panes.contains { $0.id == exitedID }
        }
        return .make("ST-04a", "프로세스 종료 시 pane 정리(새 셸로 교체)",
                     status: replaced ? .pass : .fail, cause: .app,
                     evidence: ["panes_after": "\(harness.workspace.panes.count)"], startedAt: start)
    }
}
