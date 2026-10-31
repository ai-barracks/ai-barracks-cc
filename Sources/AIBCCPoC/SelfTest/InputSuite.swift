import AppKit

/// Input acceptance tests. Each result is a sub-ID (e.g. IN-05a); parent IDs
/// are aggregated by `CriteriaCatalog`. Verdicts come from the bytes the PTY
/// recorder actually received.
@MainActor
struct InputSuite {
    let harness: SelfTestHarness

    private typealias Synth = EventSynthesizer
    private typealias Step = (key: EventSynthesizer.Key, ime: [ScriptedIMECall])

    func run() async -> [TestResult] {
        let start = ContinuousClock.now
        guard let window = harness.window,
              let primary = harness.makeRecorderPane(name: "input-a"),
              let secondary = harness.makeRecorderPane(name: "input-b")
        else { return [setupFailure("window or fixtures missing", start)] }
        guard InputSourceGuard.selectASCIIBaseline() != nil else {
            return [setupFailure("no ASCII input source (ABC/U.S.)", start)]
        }
        await harness.install([primary.pane, secondary.pane], layout: .double)
        let ready = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) {
            primary.log.isReady && secondary.log.isReady
        }
        guard ready else { return [setupFailure("recorder not ready", start)] }

        let measured = [
            await spaceKey(primary, window),
            await fastTyping(primary, window),
            await paste("IN-07a", "여러 줄 붙여넣기 중복 0", text: "붙여넣기 테스트 가나다\nsecond line", primary, window),
            await paste("IN-07b", "한 줄 붙여넣기 중복 0", text: "한 줄 붙여넣기 ok", primary, window),
            await escapeKey(primary, window),
            await commandCopyDoesNotLeak(primary, window),
            await appShortcutDoesNotLeak(primary, window),
            await contractHangulWithSpace(primary, window),
            await contractBackspaceWhileComposing(primary, window),
            await paneClickWhileComposing(primary, secondary, window),
            await syntheticKoreanPath(primary, window),
        ]
        return measured + [await bracketedPaste(window), await controlC(window)]
    }

    // MARK: - Plain keys (ASCII baseline input source)

    private func spaceKey(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        harness.focus(rec.pane)
        let mark = rec.log.mark()
        Synth.press(Synth.space, in: window)
        let bytes = await harness.settledBytes(rec.log, since: mark)
        return .make("IN-05a", "스페이스 1회 = 0x20 1바이트, NBSP 0",
                     status: bytes == [0x20] ? .pass : .fail,
                     evidence: ["hex": Hex.string(bytes)], startedAt: start)
    }

    private func fastTyping(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        harness.focus(rec.pane)
        let unit = "the quick brown fox 0123456789 "
        let text = String(String(repeating: unit, count: 7).prefix(200))
        let mark = rec.log.mark()
        let typed = Synth.type(text, in: window)
        let bytes = await harness.settledBytes(rec.log, since: mark, expectingAtLeast: text.utf8.count)
        return .make("IN-06a", "빠른 연속 타이핑(ASCII 200자) 유실·중복 0",
                     status: typed && bytes == Hex.bytes(text) ? .pass : .fail,
                     evidence: ["expected_len": "\(text.utf8.count)", "actual_len": "\(bytes.count)"],
                     startedAt: start)
    }

    private func paste(
        _ id: String, _ title: String, text: String,
        _ rec: SelfTestHarness.RecorderPane, _ window: NSWindow
    ) async -> TestResult {
        let start = ContinuousClock.now
        harness.focus(rec.pane)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let mark = rec.log.mark()
        if let key = Synth.command("v") { Synth.press(key, in: window) }
        let bytes = await harness.settledBytes(rec.log, since: mark, expectingAtLeast: text.utf8.count)
        // Fixed newline policy: non-bracketed paste sends CR for each LF.
        let expected = Hex.bytes(text.replacingOccurrences(of: "\n", with: "\r"))
        return .make(id, title, status: bytes == expected ? .pass : .fail,
                     evidence: ["hex": Hex.string(bytes), "expected": Hex.string(expected)],
                     startedAt: start)
    }

    private func escapeKey(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        harness.focus(rec.pane)
        let mark = rec.log.mark()
        Synth.press(Synth.escape, in: window)
        let bytes = await harness.settledBytes(rec.log, since: mark)
        return .make("IN-10a", "Esc → 1b", status: bytes == [0x1b] ? .pass : .fail,
                     evidence: ["hex": Hex.string(bytes)], startedAt: start)
    }

    private func commandCopyDoesNotLeak(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        harness.focus(rec.pane)
        let mark = rec.log.mark()
        if let copy = Synth.command("c") { Synth.press(copy, in: window) }
        await harness.pause(.milliseconds(300))
        let bytes = rec.log.bytes(since: mark)
        return .make("IN-11a", "선택 없을 때 ⌘C가 PTY로 새지 않음",
                     status: bytes.isEmpty ? .pass : .fail,
                     evidence: ["hex": Hex.string(bytes)], startedAt: start)
    }

    private func appShortcutDoesNotLeak(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        harness.focus(rec.pane)
        let workspace = harness.workspace
        let before = workspace.isArtifactPanelVisible
        let mark = rec.log.mark()
        guard let toggle = Synth.command("i", extra: .option) else { return setupFailure("key map", start) }
        Synth.press(toggle, in: window)
        await harness.drain()
        let toggled = workspace.isArtifactPanelVisible != before
        Synth.press(toggle, in: window)
        await harness.pause(.milliseconds(300))
        let bytes = rec.log.bytes(since: mark)
        return .make("IN-11b", "앱 단축키(⌥⌘I)가 동작하고 PTY로 새지 않음",
                     status: toggled && bytes.isEmpty ? .pass : .fail,
                     evidence: ["menu_handled": "\(toggled)", "hex": Hex.string(bytes)], startedAt: start)
    }

    // MARK: - IME callback contract (scripted IMK)

    private func contractHangulWithSpace(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> TestResult {
        let steps = keys("rksk", ime: [
            [.setMarkedText("ㄱ")], [.setMarkedText("가")],
            [.setMarkedText("간")], [.insertText("가"), .setMarkedText("나")],
        ]) + [(key: Synth.space, ime: [.insertText("나"), .insertText(" ")])]
        return await replay("IN-01a", "한글 조합: 조합 중 무전송·확정 1회·이어지는 스페이스 0x20",
                            steps: steps, expectedAfterStep: ["", "", "", "가", "가나 "], rec, window)
    }

    private func contractBackspaceWhileComposing(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> TestResult {
        let steps = keys("rks", ime: [[.setMarkedText("ㄱ")], [.setMarkedText("가")], [.setMarkedText("간")]])
            + [(key: Synth.delete, ime: [.setMarkedText("가")]),
               (key: Synth.space, ime: [.insertText("가"), .insertText(" ")])]
        return await replay("IN-02a", "조합 중 Backspace는 조합만 수정",
                            steps: steps, expectedAfterStep: ["", "", "", "", "가 "], rec, window)
    }

    /// Replays scripted IMK calls one key at a time and checks the cumulative
    /// PTY bytes after every step, so an early send during composition fails.
    private func replay(
        _ id: String, _ title: String, steps: [Step], expectedAfterStep: [String],
        _ rec: SelfTestHarness.RecorderPane, _ window: NSWindow
    ) async -> TestResult {
        let start = ContinuousClock.now
        guard let probe = rec.pane.probeView else { return setupFailure("probe view missing", start) }
        harness.focus(rec.pane)
        probe.clearReplayQueue()
        probe.clearCallLog()
        let mark = rec.log.mark()
        var mismatches: [String] = []
        for (index, step) in steps.enumerated() {
            probe.enqueueReplay(step.ime)
            Synth.press(step.key, in: window)
            await harness.drain()
            let expected = Hex.bytes(expectedAfterStep[index])
            let bytes = await harness.settledBytes(rec.log, since: mark, expectingAtLeast: expected.count)
            if bytes != expected {
                mismatches = mismatches + ["step\(index + 1)=\(Hex.string(bytes))"]
            }
        }
        let leftover = probe.pendingReplayCount
        let droppedInserts = probe.callLog.filter { $0.kind == .insertText && !$0.hadCurrentEvent }.count
        probe.clearReplayQueue()
        return .make(id, title, status: mismatches.isEmpty && leftover == 0 ? .pass : .fail,
                     layer: .imeCallbackContract,
                     evidence: ["mismatches": mismatches.joined(separator: "; "),
                                "unconsumed_scripts": "\(leftover)",
                                "insertText_without_currentEvent": "\(droppedInserts)"],
                     startedAt: start)
    }

    /// Composing in pane A, then clicking pane B: nothing may reach B except
    /// what is typed there. A's commit-or-cancel policy needs the real IME.
    private func paneClickWhileComposing(
        _ first: SelfTestHarness.RecorderPane, _ second: SelfTestHarness.RecorderPane, _ window: NSWindow
    ) async -> TestResult {
        let start = ContinuousClock.now
        guard let probe = first.pane.probeView, let key = Synth.key("r") else {
            return setupFailure("probe view missing", start)
        }
        harness.focus(first.pane)
        let markA = first.log.mark()
        let markB = second.log.mark()
        probe.enqueueReplay([.setMarkedText("ㄱ")])
        Synth.press(key, in: window)
        await harness.drain()
        await harness.click(row: 3, column: 2, in: second.pane)
        let focused = harness.isFirstResponder(second.pane.probeView)
        Synth.type("x", in: window)
        let bytesB = await harness.settledBytes(second.log, since: markB)
        probe.clearReplayQueue()
        return .make("IN-04a", "조합 중 다른 pane 클릭 시 오배달 0 (A의 확정 정책은 실제 IME로)",
                     status: focused && bytesB == [0x78] ? .pass : .fail, layer: .imeCallbackContract,
                     evidence: ["pane_b_focused": "\(focused)", "pane_b": Hex.string(bytesB),
                                "pane_a": Hex.string(first.log.bytes(since: markA))],
                     startedAt: start)
    }

    // MARK: - Synthetic events through the real input method

    private func syntheticKoreanPath(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        guard let probe = rec.pane.probeView else { return setupFailure("probe view missing", start) }
        harness.focus(rec.pane)
        probe.clearReplayQueue()
        probe.clearCallLog()
        let mark = rec.log.mark()
        let outcome = await InputSourceGuard.with(InputSourceGuard.korean2Set) { () -> [UInt8] in
            Synth.type("rksk ", in: window)
            return await harness.settledBytes(rec.log, since: mark)
        }
        let bytes = outcome ?? []
        let engaged = probe.callLog.contains { $0.kind == .setMarkedText }
        saveCallLog(probe.callLog, name: "synthetic-korean-calllog.json")
        let verdict = syntheticVerdict(selected: outcome != nil, engaged: engaged, bytes: bytes)
        return .make("IN-01-syn", "합성 이벤트 → 실제 입력기(IMK) 경유 한글 조합",
                     status: verdict, layer: .syntheticEventPath,
                     evidence: ["korean_source_selected": "\(outcome != nil)", "imk_engaged": "\(engaged)",
                                "hex": Hex.string(bytes)],
                     startedAt: start)
    }

    private func syntheticVerdict(selected: Bool, engaged: Bool, bytes: [UInt8]) -> TestStatus {
        let nbsp: [UInt8] = [0xc2, 0xa0]
        let hasNBSP = bytes.indices.dropLast().contains { Array(bytes[$0...$0 + 1]) == nbsp }
        if hasNBSP { return .fail }
        guard selected, engaged else { return .unverified }
        return bytes == Hex.bytes("가나 ") ? .pass : .fail
    }

    // MARK: - Separate fixtures

    /// IN-08a: with bracketed paste on, an embedded end marker must not
    /// terminate the paste early (exactly one ESC[201~, at the end).
    private func bracketedPaste(_ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        guard let rec = harness.makeRecorderPane(name: "bracketed", environment: ["AIBCC_BRACKETED_PASTE": "1"]),
              let key = Synth.command("v")
        else { return setupFailure("bracketed fixture missing", start) }
        await harness.install([rec.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { rec.log.isReady }
        harness.focus(rec.pane)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("abc\u{1b}[201~rm -rf x\ndef", forType: .string)
        let mark = rec.log.mark()
        Synth.press(key, in: window)
        let bytes = await harness.settledBytes(rec.log, since: mark, expectingAtLeast: 12)
        let startMarker = Hex.bytes("\u{1b}[200~")
        let endMarker = Hex.bytes("\u{1b}[201~")
        let closes = occurrences(of: endMarker, in: bytes)
        let ok = bytes.starts(with: startMarker) && closes == 1 && Array(bytes.suffix(endMarker.count)) == endMarker
        return .make("IN-08a", "bracketed paste 내부 종료 구분자 무력화",
                     status: ok ? .pass : .fail, evidence: ["hex": Hex.string(bytes), "end_markers": "\(closes)"],
                     startedAt: start)
    }

    private func controlC(_ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        let temp = FileManager.default.temporaryDirectory
        let ready = temp.appendingPathComponent("aibcc-sigint-ready-\(UUID().uuidString)")
        let signalled = temp.appendingPathComponent("aibcc-sigint-hit-\(UUID().uuidString)")
        guard let pane = harness.makeScriptPane(
            name: "sigint", script: "sigint_probe.sh", readyFile: ready,
            environment: [AppConstants.Environment.signalFile: signalled.path]
        ), let key = Synth.control("c") else { return setupFailure("sigint fixture missing", start) }
        await harness.install([pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) {
            FileManager.default.fileExists(atPath: ready.path)
        }
        harness.focus(pane)
        Synth.press(key, in: window)
        let hit = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            FileManager.default.fileExists(atPath: signalled.path)
        }
        return .make("IN-09a", "Ctrl+C → foreground 프로세스 그룹 SIGINT (trap 실행)",
                     status: hit ? .pass : .fail, startedAt: start)
    }

    // MARK: - Helpers

    private func keys(_ letters: String, ime: [[ScriptedIMECall]]) -> [Step] {
        zip(letters, ime).compactMap { letter, calls in
            Synth.key(letter).map { (key: $0, ime: calls) }
        }
    }

    private func occurrences(of needle: [UInt8], in haystack: [UInt8]) -> Int {
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
        return (0...(haystack.count - needle.count)).filter { Array(haystack[$0..<$0 + needle.count]) == needle }.count
    }

    private func saveCallLog(_ log: [InputCallRecord], name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(log) else { return }
        try? data.write(to: harness.outputDirectory.appendingPathComponent(name), options: .atomic)
    }

    private func setupFailure(_ reason: String, _ start: ContinuousClock.Instant) -> TestResult {
        .make("IN-setup", "입력 스위트 준비", status: .fail, cause: .app,
              evidence: ["reason": reason], startedAt: start)
    }
}
