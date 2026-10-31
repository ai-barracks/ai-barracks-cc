import AppKit
import GhosttyTerminal

/// Resize acceptance tests. After each change the suite first confirms the
/// change was applied, then requires the triad — app grid == PTY winsize,
/// surface pixels == view backing size, grid + both paddings fit — to hold
/// continuously for `stableWindow`. Visibility of the last row/column needs a
/// composited capture and is reported separately (RS-01b).
@MainActor
struct ResizeSuite {
    let harness: SelfTestHarness

    private struct Convergence {
        let converged: Bool
        let millis: Double
        let detail: String
    }

    private struct Geometry: Equatable {
        let columns: Int, rows: Int, viewWidth: Int, viewHeight: Int, cellWidth: Int
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
        let groups = [
            await windowSequence(rec, window),
            await panelAndLayoutChanges(rec),
            await fontSizeActions(rec),
            await fontSizeShortcuts(rec, window),
            await fullScreen(rec, window),
        ]
        window.setFrame(original, display: true)
        harness.workspace.isArtifactPanelVisible = true
        return groups.flatMap { $0 }
    }

    // MARK: - Scenarios

    private func windowSequence(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> [TestResult] {
        let start = ContinuousClock.now
        let sizes = stepSizes(for: window)
        var outcomes: [Convergence] = []
        var captures: [String] = []
        for (index, size) in sizes.enumerated() {
            outcomes = outcomes + [await apply(rec) { window.setContentSize(size) }]
            if index == 0 || index == sizes.count / 2 || index == sizes.count - 1,
               let image = await harness.requestCapture(label: "resize-step\(index)") {
                captures = captures + [image.lastPathComponent]
            }
        }
        let failures = outcomes.filter { !$0.converged }
        let slowest = outcomes.map(\.millis).max() ?? 0
        let budget = AppConstants.SelfTest.resizeConvergenceBudget.milliseconds
        return [
            .make("RS-01a", "창 연속 축소·확대 \(sizes.count)단계 grid·PTY·픽셀 일치",
                  status: failures.isEmpty ? .pass : .fail,
                  evidence: ["failed": failures.map(\.detail).joined(separator: " | ")], startedAt: start),
            .make("RS-01b", "마지막 행·열(BR 표식) 실제 표시 — 캡처 검토 필요",
                  status: .unverified,
                  evidence: ["captures": captures.isEmpty ? "none (capture-watcher not running)" : captures.joined(separator: ", ")],
                  startedAt: start),
            .make("RS-08a", "리사이즈 수렴 시간(후보 \(Int(budget))ms, 비차단)",
                  status: slowest <= budget ? .pass : .fail,
                  evidence: ["slowest_ms": String(format: "%.1f", slowest)], startedAt: start),
        ]
    }

    private func panelAndLayoutChanges(_ rec: SelfTestHarness.RecorderPane) async -> [TestResult] {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        let readyBefore = readyCount(rec)
        let outcomes = [
            await apply(rec) { workspace.isArtifactPanelVisible = false },
            await apply(rec) { workspace.isArtifactPanelVisible = true },
            await apply(rec) { workspace.setLayout(.double) },
            await apply(rec) { workspace.setLayout(.quad) },
            await apply(rec) { workspace.setLayout(.single) },
        ]
        let restarted = readyCount(rec) != readyBefore
        let failures = outcomes.filter { !$0.converged }
        return [.make("RS-03a", "패널 열기·닫기, 1→2→4→1 분할 전환: 3자 일치 + 프로세스 유지",
                      status: failures.isEmpty && !restarted ? .pass : .fail,
                      evidence: ["process_restarted": "\(restarted)",
                                 "failed": failures.map(\.detail).joined(separator: " | ")],
                      startedAt: start)]
    }

    private func fontSizeActions(_ rec: SelfTestHarness.RecorderPane) async -> [TestResult] {
        let start = ContinuousClock.now
        var notes: [String] = []
        for action in ["increase_font_size:2", "decrease_font_size:4", "reset_font_size"] {
            let before = rec.pane.state.fontSize
            var handled = false
            let outcome = await apply(rec) { handled = rec.pane.state.performBindingAction(action) }
            let changed = rec.pane.state.fontSize != before
            if !(handled && changed && outcome.converged) {
                notes = notes + ["\(action): handled=\(handled) changed=\(changed) \(outcome.detail)"]
            }
        }
        return [.make("RS-04a", "폰트 크기 변경(바인딩 액션) 3자 일치",
                      status: notes.isEmpty ? .pass : .fail,
                      evidence: ["failed": notes.joined(separator: " | ")], startedAt: start)]
    }

    private func fontSizeShortcuts(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> [TestResult] {
        let start = ContinuousClock.now
        harness.focus(rec.pane)
        let keys = [EventSynthesizer.commandEqual, EventSynthesizer.commandMinus, EventSynthesizer.commandMinus]
            + [EventSynthesizer.command("0")].compactMap { $0 }
        var notes: [String] = []
        for key in keys {
            let before = rec.pane.state.fontSize
            let outcome = await apply(rec) { EventSynthesizer.press(key, in: window) }
            if rec.pane.state.fontSize == before || !outcome.converged {
                notes = notes + ["\(key.characters): \(outcome.detail)"]
            }
        }
        return [.make("RS-04b", "⌘= / ⌘− / ⌘0 단축키 폰트 변경 3자 일치",
                      status: notes.isEmpty ? .pass : .fail,
                      evidence: ["failed": notes.joined(separator: " | ")], startedAt: start)]
    }

    private func fullScreen(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> [TestResult] {
        let start = ContinuousClock.now
        let inside = await apply(rec, settle: .seconds(6)) { window.toggleFullScreen(nil) }
        let entered = window.styleMask.contains(.fullScreen)
        let outside = await apply(rec, settle: .seconds(6)) { window.toggleFullScreen(nil) }
        let exited = !window.styleMask.contains(.fullScreen)
        let ok = entered && exited && inside.converged && outside.converged
        return [.make("RS-02a", "전체화면 진입·해제 3자 일치",
                      status: ok ? .pass : .fail,
                      evidence: ["entered": "\(entered)", "exited": "\(exited)",
                                 "inside": inside.detail, "outside": outside.detail],
                      startedAt: start)]
    }

    // MARK: - Convergence

    /// Applies `change`, waits until the geometry actually differs (or a grace
    /// period passes for no-op changes), then until the triad holds for a
    /// full `stableWindow`. Time is measured from the request.
    private func apply(
        _ rec: SelfTestHarness.RecorderPane,
        settle: Duration = AppConstants.SelfTest.settleTimeout,
        _ change: () -> Void
    ) async -> Convergence {
        let before = geometry(rec)
        let requested = ContinuousClock.now
        change()
        let deadline = requested + settle
        var changed = false
        var agreeingSince: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            changed = changed || geometry(rec) != before || ContinuousClock.now - requested > AppConstants.SelfTest.changeGrace
            if changed && triadAgrees(rec) {
                let since = agreeingSince ?? ContinuousClock.now
                agreeingSince = since
                if ContinuousClock.now - since >= AppConstants.SelfTest.stableWindow {
                    return Convergence(converged: true, millis: (since - requested).milliseconds, detail: describe(rec))
                }
            } else {
                agreeingSince = nil
            }
            await harness.pause(AppConstants.SelfTest.pollInterval)
        }
        return Convergence(converged: false, millis: settle.milliseconds, detail: "timeout " + describe(rec))
    }

    private func geometry(_ rec: SelfTestHarness.RecorderPane) -> Geometry? {
        guard let grid = rec.pane.state.surfaceSize, let view = rec.pane.probeView else { return nil }
        return Geometry(columns: Int(grid.columns), rows: Int(grid.rows),
                        viewWidth: Int(view.bounds.width), viewHeight: Int(view.bounds.height),
                        cellWidth: Int(grid.cellWidthPixels))
    }

    private func triadAgrees(_ rec: SelfTestHarness.RecorderPane) -> Bool {
        guard let grid = rec.pane.state.surfaceSize, let pty = rec.log.lastWinsize(),
              let view = rec.pane.probeView, let window = view.window
        else { return false }
        let scale = window.backingScaleFactor
        let gridMatchesPTY = Int(grid.columns) == pty.cols && Int(grid.rows) == pty.rows
        let surfaceMatchesView = abs(CGFloat(grid.widthPixels) - view.bounds.width * scale) <= 2
            && abs(CGFloat(grid.heightPixels) - view.bounds.height * scale) <= 2
        let paddingX = 2 * CGFloat(AppConstants.Terminal.paddingX) * scale
        let paddingY = 2 * CGFloat(AppConstants.Terminal.paddingY) * scale
        let usedWidth = CGFloat(UInt32(grid.columns) * grid.cellWidthPixels) + paddingX
        let usedHeight = CGFloat(UInt32(grid.rows) * grid.cellHeightPixels) + paddingY
        let gridFits = usedWidth <= CGFloat(grid.widthPixels) + 1 && usedHeight <= CGFloat(grid.heightPixels) + 1
        return gridMatchesPTY && surfaceMatchesView && gridFits
    }

    private func describe(_ rec: SelfTestHarness.RecorderPane) -> String {
        let grid = rec.pane.state.surfaceSize.map { "\($0.columns)x\($0.rows) px \($0.widthPixels)x\($0.heightPixels)" } ?? "nil"
        let pty = rec.log.lastWinsize().map { "\($0.cols)x\($0.rows)" } ?? "nil"
        let bounds = rec.pane.probeView.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))pt" } ?? "nil"
        return "grid \(grid) / pty \(pty) / view \(bounds)"
    }

    private func readyCount(_ rec: SelfTestHarness.RecorderPane) -> Int {
        rec.log.events().filter { $0.kind == "ready" }.count
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

    private func setupFailure(_ reason: String, _ start: ContinuousClock.Instant) -> TestResult {
        .make("RS-setup", "리사이즈 스위트 준비", status: .fail, cause: .app,
              evidence: ["reason": reason], startedAt: start)
    }
}
