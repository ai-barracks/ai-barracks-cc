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
        static let longRow = 4
        static let words = "alpha beta gamma"
        static let hangul = "한글 선택 테스트 가나다"
        static let wide = "emoji 🙂 wide 漢字 end"
        static let trailing = "trailing spaces"
        static let long = "LONG:" + String(repeating: "abcdefghij", count: 30)
    }

    func run() async -> [TestResult] {
        let start = ContinuousClock.now
        let ready = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibcc-selection-ready-\(UUID().uuidString)")
        guard let window = harness.window,
              let pane = harness.makeScriptPane(name: "selection", script: AppConstants.Paths.selectionScript, readyFile: ready)
        else { return [setupFailure("window or fixtures missing", start)] }
        await harness.install([pane], layout: .single)
        let shown = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) {
            FileManager.default.fileExists(atPath: ready.path)
        }
        guard shown else { return [setupFailure("selection fixture not ready", start)] }
        await harness.pause(.milliseconds(300))

        let fixtureResults = [
            await dragWord(pane, window),
            await doubleClickWord(pane, window),
            await tripleClick("SC-02b", "트리플클릭 줄", row: Fixture.wordsRow, expected: Fixture.words, pane, window),
            await rectangle(pane, window),
            await tripleClick("SC-04a", "soft-wrap 긴 줄은 한 줄로 복사", row: Fixture.longRow, expected: Fixture.long, pane, window),
            await tripleClick("SC-04b", "줄 끝 공백 정리", row: Fixture.trailingRow, expected: Fixture.trailing, pane, window),
            await tripleClick("SC-05a", "한글 선택 복사", row: Fixture.hangulRow, expected: Fixture.hangul, pane, window),
            await tripleClick("SC-05b", "이모지·wide char 선택 복사", row: Fixture.wideRow, expected: Fixture.wide, pane, window),
        ]
        return fixtureResults + (await mouseCapturedTUI(window))
    }

    // MARK: - Scenarios

    private func dragWord(_ pane: TerminalPane, _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        guard let from = harness.windowPoint(row: Fixture.wordsRow, column: 0, in: pane, fraction: 0.1),
              let to = harness.windowPoint(row: Fixture.wordsRow, column: 4, in: pane, fraction: 0.9)
        else { return setupFailure("geometry unavailable", start) }
        Synth.drag(from: from, to: to, steps: 8, in: window)
        let copied = await copySelection(window)
        return verdict("SC-01", "드래그 선택 → ⌘C", copied: copied, expected: "alpha", start)
    }

    private func doubleClickWord(_ pane: TerminalPane, _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
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
        guard let point = harness.windowPoint(row: row, column: 1, in: pane) else {
            return setupFailure("geometry unavailable", start)
        }
        Synth.click(at: point, count: 3, in: window)
        let copied = await copySelection(window)
        return verdict(id, title, copied: copied.map(trimTrailingWhitespace), expected: expected, start)
    }

    private func rectangle(_ pane: TerminalPane, _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        guard let from = harness.windowPoint(row: Fixture.wordsRow, column: 0, in: pane, fraction: 0.1),
              let to = harness.windowPoint(row: Fixture.hangulRow, column: 4, in: pane, fraction: 0.9)
        else { return setupFailure("geometry unavailable", start) }
        Synth.drag(from: from, to: to, steps: 8, in: window, modifiers: .option)
        let copied = await copySelection(window).map(trimTrailingWhitespace)
        return verdict("SC-03", "Option+드래그 사각 선택", copied: copied, expected: "alpha\n한글", start)
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
        harness.focus(rec.pane)
        let typedMark = rec.log.mark()
        Synth.type("x", in: window)
        let typed = await harness.settledBytes(rec.log, since: typedMark)
        let selectOK = captured && copied == "rows=" && leaked.isEmpty
        return [
            .make("SC-06", "TUI 마우스 점유 중 Shift+드래그 선택",
                  status: selectOK ? .pass : .fail,
                  evidence: ["mouse_captured": "\(captured)", "copied": copied ?? "nil",
                             "pty_bytes_during_drag": Hex.string(leaked)],
                  startedAt: start),
            .make("SC-08", "복사 후 터미널 입력 유지",
                  status: typed == [0x78] ? .pass : .fail,
                  evidence: ["hex": Hex.string(typed)], startedAt: start),
        ]
    }

    // MARK: - Helpers

    private func copySelection(_ window: NSWindow) async -> String? {
        harness.clearPasteboard()
        if let copy = Synth.command("c") { Synth.press(copy, in: window) }
        _ = await harness.waitUntil(.milliseconds(500)) { harness.pasteboardString != nil }
        return harness.pasteboardString
    }

    private func trimTrailingWhitespace(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in String(line.reversed().drop { $0 == " " || $0 == "\r" }.reversed()) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    private func verdict(
        _ id: String, _ title: String, copied: String?, expected: String,
        _ start: ContinuousClock.Instant
    ) -> TestResult {
        .make(id, title, status: copied == expected ? .pass : .fail,
              evidence: ["copied": copied ?? "nil", "expected": expected], startedAt: start)
    }

    private func setupFailure(_ reason: String, _ start: ContinuousClock.Instant) -> TestResult {
        .make("SC-setup", "선택 스위트 준비", status: .fail, cause: .app,
              evidence: ["reason": reason], startedAt: start)
    }
}
