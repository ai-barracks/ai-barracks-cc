import AppKit
import GhosttyTerminal

/// Resize acceptance tests (RS-*). After each change the suite waits for the
/// triad to agree — app grid == PTY winsize, surface pixels == view backing
/// size, grid fits inside the surface — and records convergence time.
@MainActor
struct ResizeSuite {
    let harness: SelfTestHarness

    private struct Convergence {
        let converged: Bool
        let millis: Double
        let detail: String
    }

    func run() async -> [TestResult] {
        let start = ContinuousClock.now
        guard let window = harness.window, let rec = harness.makeRecorderPane(name: "resize") else {
            return [setupFailure("window or fixtures missing", start)]
        }
        await harness.install([rec.pane], layout: .single)
        guard await harness.waitUntil(AppConstants.SelfTest.readyTimeout, { rec.log.isReady }) else {
            return [setupFailure("recorder not ready", start)]
        }
        let original = window.frame
        let results = [
            await windowSequence(rec, window),
            await panelAndSplitChanges(rec),
            await fontSizeChanges(rec),
            await fullScreen(rec, window),
        ]
        window.setFrame(original, display: true)
        harness.workspace.isArtifactPanelVisible = true
        return results.flatMap { $0 }
    }

    // MARK: - Scenarios

    private func windowSequence(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> [TestResult] {
        let start = ContinuousClock.now
        let sizes = stepSizes(for: window)
        var outcomes: [Convergence] = []
        for (index, size) in sizes.enumerated() {
            window.setContentSize(size)
            outcomes = outcomes + [await converge(rec)]
            if index == sizes.count / 2 { saveSnapshot(rec.pane, name: "resize-smallest.png") }
        }
        saveSnapshot(rec.pane, name: "resize-final.png")
        let failures = outcomes.filter { !$0.converged }
        let slowest = outcomes.map(\.millis).max() ?? 0
        let budget = AppConstants.SelfTest.resizeConvergenceBudget.milliseconds
        return [
            .make("RS-01", "창 연속 축소·확대 \(sizes.count)단계 3자 일치",
                  status: failures.isEmpty ? .pass : .fail,
                  evidence: ["steps": "\(sizes.count)", "failed": failures.map(\.detail).joined(separator: " | ")],
                  startedAt: start),
            .make("RS-08", "리사이즈 수렴 시간(후보 \(Int(budget))ms, 비차단)",
                  status: slowest <= budget ? .pass : .fail, cause: .unknown,
                  evidence: ["slowest_ms": String(format: "%.1f", slowest)], startedAt: start),
        ]
    }

    private func panelAndSplitChanges(_ rec: SelfTestHarness.RecorderPane) async -> [TestResult] {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        var outcomes: [Convergence] = []
        workspace.isArtifactPanelVisible = false
        outcomes = outcomes + [await converge(rec)]
        workspace.isArtifactPanelVisible = true
        outcomes = outcomes + [await converge(rec)]
        workspace.setLayout(.double)
        outcomes = outcomes + [await converge(rec)]
        workspace.setLayout(.single)
        outcomes = outcomes + [await converge(rec)]
        let failures = outcomes.filter { !$0.converged }
        return [.make("RS-03", "산출물 패널 열기·닫기, 분할 전환 3자 일치 (경계 드래그는 수동)",
                      status: failures.isEmpty ? .pass : .fail,
                      evidence: ["failed": failures.map(\.detail).joined(separator: " | ")],
                      startedAt: start)]
    }

    private func fontSizeChanges(_ rec: SelfTestHarness.RecorderPane) async -> [TestResult] {
        let start = ContinuousClock.now
        let actions = ["increase_font_size:2", "decrease_font_size:4", "reset_font_size"]
        var outcomes: [Convergence] = []
        for action in actions {
            _ = rec.pane.state.performBindingAction(action)
            outcomes = outcomes + [await converge(rec)]
        }
        let failures = outcomes.filter { !$0.converged }
        return [.make("RS-04", "폰트 크기 변경 ⌘+/⌘−/⌘0 3자 일치",
                      status: failures.isEmpty ? .pass : .fail,
                      evidence: ["failed": failures.map(\.detail).joined(separator: " | ")],
                      startedAt: start)]
    }

    private func fullScreen(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> [TestResult] {
        let start = ContinuousClock.now
        window.toggleFullScreen(nil)
        let entered = await harness.waitUntil(.seconds(5)) { window.styleMask.contains(.fullScreen) }
        let inside = await converge(rec)
        window.toggleFullScreen(nil)
        let exited = await harness.waitUntil(.seconds(5)) { !window.styleMask.contains(.fullScreen) }
        let outside = await converge(rec)
        let ok = entered && exited && inside.converged && outside.converged
        return [.make("RS-02", "전체화면 진입·해제 3자 일치",
                      status: ok ? .pass : .fail,
                      evidence: ["entered": "\(entered)", "exited": "\(exited)",
                                 "inside": inside.detail, "outside": outside.detail],
                      startedAt: start)]
    }

    // MARK: - Triad

    private func converge(_ rec: SelfTestHarness.RecorderPane) async -> Convergence {
        let start = ContinuousClock.now
        let agreed = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { triadAgrees(rec) }
        let millis = (ContinuousClock.now - start).milliseconds
        await harness.pause(AppConstants.SelfTest.stableWindow)
        let stable = agreed && triadAgrees(rec)
        return Convergence(converged: stable, millis: millis, detail: describe(rec))
    }

    private func triadAgrees(_ rec: SelfTestHarness.RecorderPane) -> Bool {
        guard let grid = rec.pane.state.surfaceSize, let pty = rec.log.lastWinsize(),
              let view = rec.pane.probeView, let window = view.window
        else { return false }
        let scale = window.backingScaleFactor
        let gridMatchesPTY = Int(grid.columns) == pty.cols && Int(grid.rows) == pty.rows
        let surfaceMatchesView = abs(CGFloat(grid.widthPixels) - view.bounds.width * scale) <= 2
            && abs(CGFloat(grid.heightPixels) - view.bounds.height * scale) <= 2
        let paddingX = CGFloat(AppConstants.Terminal.paddingX) * scale
        let paddingY = CGFloat(AppConstants.Terminal.paddingY) * scale
        let gridFits = CGFloat(UInt32(grid.columns) * grid.cellWidthPixels) + paddingX <= CGFloat(grid.widthPixels)
            && CGFloat(UInt32(grid.rows) * grid.cellHeightPixels) + paddingY <= CGFloat(grid.heightPixels)
        return gridMatchesPTY && surfaceMatchesView && gridFits
    }

    private func describe(_ rec: SelfTestHarness.RecorderPane) -> String {
        let grid = rec.pane.state.surfaceSize.map { "\($0.columns)x\($0.rows) px \($0.widthPixels)x\($0.heightPixels)" } ?? "nil"
        let pty = rec.log.lastWinsize().map { "\($0.cols)x\($0.rows)" } ?? "nil"
        let bounds = rec.pane.probeView.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))pt" } ?? "nil"
        return "grid \(grid) / pty \(pty) / view \(bounds)"
    }

    // MARK: - Helpers

    private func stepSizes(for window: NSWindow) -> [NSSize] {
        let visible = window.screen?.visibleFrame.size ?? AppConstants.SelfTest.resizeLargeSize
        let large = NSSize(
            width: min(AppConstants.SelfTest.resizeLargeSize.width, visible.width - 40),
            height: min(AppConstants.SelfTest.resizeLargeSize.height, visible.height - 80)
        )
        let small = AppConstants.SelfTest.resizeSmallSize
        let half = AppConstants.SelfTest.resizeSteps / 2
        let shrink = (0...half).map { interpolate(large, small, CGFloat($0) / CGFloat(half)) }
        let grow = (1...half).map { interpolate(small, large, CGFloat($0) / CGFloat(half)) }
        return shrink + grow
    }

    private func interpolate(_ from: NSSize, _ to: NSSize, _ t: CGFloat) -> NSSize {
        NSSize(width: (from.width + (to.width - from.width) * t).rounded(),
               height: (from.height + (to.height - from.height) * t).rounded())
    }

    private func saveSnapshot(_ pane: TerminalPane, name: String) {
        guard let image = pane.probeView?.snapshotImage(),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: harness.outputDirectory.appendingPathComponent(name))
    }

    private func setupFailure(_ reason: String, _ start: ContinuousClock.Instant) -> TestResult {
        .make("RS-setup", "리사이즈 스위트 준비", status: .fail, cause: .app,
              evidence: ["reason": reason], startedAt: start)
    }
}
