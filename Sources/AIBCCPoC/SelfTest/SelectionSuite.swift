import AppKit

/// Selection & copy acceptance tests (SC-*). Selections are made with
/// synthetic mouse events on the real view and copied with a synthetic ⌘C
/// through `NSApp.sendEvent`, then read back from the pasteboard.
@MainActor
struct SelectionSuite {
    let harness: SelfTestHarness

    private typealias Synth = EventSynthesizer

    /// Mirrors Fixtures/selection_text.sh (0-based rows).
    private enum Fixture {
        static let wordsRow = 0
        static let hangulRow = 1
        static let wideRow = 2
        static let trailingRow = 3
        static let wrapRow = 4
        static let longRow = 6
        static let words = "alpha beta gamma"
        static let hangul = "한글 선택 테스트 가나다"
        static let wide = "emoji 🙂 wide 漢字 end"
        static let trailing = "trailing spaces"
        static let long = "LONG:" + String(repeating: "abcdefghij", count: 30)
    }

    func run() async -> [TestResult] {
        let start = ContinuousClock.now
        let temp = FileManager.default.temporaryDirectory
        let ready = temp.appendingPathComponent("aibcc-selection-ready-\(UUID().uuidString)")
        let go = temp.appendingPathComponent("aibcc-selection-go-\(UUID().uuidString)")
        guard let window = harness.window,
              let pane = harness.makeScriptPane(
                  name: "selection", script: AppConstants.Paths.selectionScript, readyFile: ready,
                  environment: ["AIBCC_GO_FILE": go.path]
              )
        else { return [setupFailure("window or fixtures missing", start)] }
        await harness.install([pane], layout: .single)
        await waitForStableGrid(pane)
        FileManager.default.createFile(atPath: go.path, contents: nil)
        let shown = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) {
            FileManager.default.fileExists(atPath: ready.path)
        }
        guard shown else { return [setupFailure("selection fixture not ready", start)] }
        await harness.pause(.milliseconds(300))
        harness.focus(pane)

        let fixtureResults = [
            await dragWord(pane, window),
            await doubleClickWord(pane, window),
            await tripleClick("SC-02b", "트리플클릭 줄", row: Fixture.wordsRow, expected: Fixture.words, pane, window),
            await rectangle(pane, window),
            await tripleClick("SC-04a", "soft-wrap 긴 줄은 한 줄로 복사", row: Fixture.longRow, expected: Fixture.long, pane, window),
            await tripleClick("SC-04b", "줄 끝 공백 정리", row: Fixture.trailingRow, expected: Fixture.trailing, pane, window),
            await tripleClick("SC-05a", "한글 선택 복사", row: Fixture.hangulRow, expected: Fixture.hangul, pane, window),
            await tripleClick("SC-05b", "이모지·wide char 선택 복사", row: Fixture.wideRow, expected: Fixture.wide, pane, window),
            await tripleClick("SC-05c", "줄 끝에 걸쳐 줄바꿈된 wide char 연속 복사", row: Fixture.wrapRow,
                              expected: wrapExpected(pane), pane, window),
        ]
        return fixtureResults + (await mouseCapturedTUI(window))
    }

    // MARK: - Scenarios

    private func dragWord(_ pane: TerminalPane, _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        await harness.pause(AppConstants.SelfTest.clickReset)
        guard let from = harness.windowPoint(row: Fixture.wordsRow, column: 0, in: pane, fraction: 0.1),
              let to = harness.windowPoint(row: Fixture.wordsRow, column: 4, in: pane, fraction: 0.9)
        else { return setupFailure("geometry unavailable", start) }
        Synth.drag(from: from, to: to, steps: 8, in: window)
        let copied = await copySelection(window)
        return verdict("SC-01a", "드래그 선택 → ⌘C", copied: copied, expected: "alpha", start)
    }

    private func doubleClickWord(_ pane: TerminalPane, _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        await harness.pause(AppConstants.SelfTest.clickReset)
        guard let point = harness.windowPoint(row: Fixture.wordsRow, column: 7, in: pane) else {
            return setupFailure("geometry unavailable", start)
        }
        Synth.click(at: point, count: 2, in: window)
        let copied = await copySelection(window)
        return verdict("SC-02a", "더블클릭 단어", copied: copied, expected: "beta", start)
    }

    private func tripleClick(
        _ id: String, _ title: String, row: Int, expected: String,
        _ pane: TerminalPane, _ window: NSWindow
    ) async -> TestResult {
        let start = ContinuousClock.now
        await harness.pause(AppConstants.SelfTest.clickReset)
        guard let point = harness.windowPoint(row: row, column: 1, in: pane) else {
            return setupFailure("geometry unavailable", start)
        }
        Synth.click(at: point, count: 3, in: window)
        let copied = await copySelection(window)
        return verdict(id, title, copied: copied, expected: expected, start)
    }

    private func rectangle(_ pane: TerminalPane, _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        await harness.pause(AppConstants.SelfTest.clickReset)
        guard let from = harness.windowPoint(row: Fixture.wordsRow, column: 0, in: pane, fraction: 0.1),
              let to = harness.windowPoint(row: Fixture.hangulRow, column: 4, in: pane, fraction: 0.9)
        else { return setupFailure("geometry unavailable", start) }
        Synth.drag(from: from, to: to, steps: 8, in: window, modifiers: .option)
        let copied = await copySelection(window)
        return verdict("SC-03a", "Option+드래그 사각 선택", copied: copied, expected: "alpha\n한글", start)
    }

    /// SC-06 + SC-08: a TUI that captured the mouse must still allow
    /// Shift+drag selection, and typing after the copy must reach the PTY.
    private func mouseCapturedTUI(_ window: NSWindow) async -> [TestResult] {
        let start = ContinuousClock.now
        guard let rec = harness.makeRecorderPane(name: "mouse", environment: ["AIBCC_MOUSE_REPORT": "1"]) else {
            return [setupFailure("recorder missing", start)]
        }
        await harness.install([rec.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { rec.log.isReady }
        let captured = await harness.waitUntil(.seconds(2)) { rec.pane.state.isMouseCaptured }
        guard let from = harness.windowPoint(row: 1, column: 0, in: rec.pane, fraction: 0.1),
              let to = harness.windowPoint(row: 1, column: 4, in: rec.pane, fraction: 0.9)
        else { return [setupFailure("geometry unavailable", start)] }
        let mark = rec.log.mark()
        Synth.drag(from: from, to: to, steps: 8, in: window, modifiers: .shift)
        let copied = await copySelection(window)
        let leaked = rec.log.bytes(since: mark)
        let stillFocused = harness.isFirstResponder(rec.pane.probeView)
        let typedMark = rec.log.mark()
        Synth.type("x", in: window)
        let typed = await harness.settledBytes(rec.log, since: typedMark)
        let selectOK = captured && copied == "rows=" && leaked.isEmpty
        return [
            .make("SC-06a", "TUI 마우스 점유 중 Shift+드래그 선택",
                  status: selectOK ? .pass : .fail,
                  evidence: ["mouse_captured": "\(captured)", "copied": copied ?? "nil",
                             "pty_bytes_during_drag": Hex.string(leaked)],
                  startedAt: start),
            .make("SC-08a", "복사 후 재포커스 없이 터미널 입력 유지",
                  status: stillFocused && typed == [0x78] ? .pass : .fail,
                  evidence: ["first_responder_kept": "\(stillFocused)", "hex": Hex.string(typed)],
                  startedAt: start),
        ]
    }

    // MARK: - Helpers

    /// The fixture lays out rows for the width it sees; start it only after
    /// the grid stopped changing for `stableWindow`.
    private func waitForStableGrid(_ pane: TerminalPane) async {
        var last = pane.state.surfaceSize
        var stableSince = ContinuousClock.now
        let deadline = ContinuousClock.now + AppConstants.SelfTest.settleTimeout
        while ContinuousClock.now < deadline {
            await harness.pause(AppConstants.SelfTest.pollInterval)
            let current = pane.state.surfaceSize
            if current != last {
                last = current
                stableSince = ContinuousClock.now
            } else if current != nil, ContinuousClock.now - stableSince >= AppConstants.SelfTest.stableWindow {
                return
            }
        }
    }

    private func copySelection(_ window: NSWindow) async -> String? {
        harness.clearPasteboard()
        if let copy = Synth.command("c") { Synth.press(copy, in: window) }
        _ = await harness.waitUntil(.milliseconds(500)) { harness.pasteboardString != nil }
        return harness.pasteboardString
    }

    /// Fixture prints (columns - 1) "w" then two wide characters.
    private func wrapExpected(_ pane: TerminalPane) -> String {
        let columns = Int(pane.state.surfaceSize?.columns ?? 80)
        return String(repeating: "w", count: max(columns - 1, 0)) + "漢字"
    }

    private func verdict(
        _ id: String, _ title: String, copied: String?, expected: String,
        _ start: ContinuousClock.Instant
    ) -> TestResult {
        .make(id, title, status: copied == expected ? .pass : .fail,
              evidence: ["copied": copied ?? "nil", "copied_hex": copied.map { Hex.string(Hex.bytes($0)) } ?? "nil",
                         "expected": expected],
              startedAt: start)
    }

    private func setupFailure(_ reason: String, _ start: ContinuousClock.Instant) -> TestResult {
        .make("SC-setup", "선택 스위트 준비", status: .fail, cause: .app,
              evidence: ["reason": reason], startedAt: start)
    }
}
