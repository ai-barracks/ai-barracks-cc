import AppKit

/// Input acceptance tests (IN-*). Every verdict is based on the bytes the
/// PTY recorder actually received.
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

        await harness.install([primary.pane, secondary.pane], layout: .double)
        let ready = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) {
            primary.log.isReady && secondary.log.isReady
        }
        guard ready else { return [setupFailure("recorder not ready", start)] }

        let core = [
            await spaceKey(primary, window),
            await fastTyping(primary, window),
            await paste(primary, window),
            await escapeKey(primary, window),
            await commandKeysDoNotLeak(primary, window),
            await contractHangulWithSpace(primary, window),
            await contractBackspaceWhileComposing(primary, window),
            await paneSwitchWhileComposing(primary, secondary, window),
            await syntheticKoreanPath(primary, window),
        ]
        return core + [await controlC(window)]
    }

    // MARK: - Plain keys

    private func spaceKey(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        harness.focus(rec.pane)
        let mark = rec.log.mark()
        Synth.press(Synth.space, in: window)
        let bytes = await harness.settledBytes(rec.log, since: mark)
        return .make("IN-05", "스페이스 1회 = 0x20 1바이트, NBSP 0",
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
        let ok = typed && bytes == Hex.bytes(text)
        return .make("IN-06", "빠른 연속 타이핑 200자 유실·중복 0",
                     status: ok ? .pass : .fail,
                     evidence: ["expected_len": "\(text.utf8.count)", "actual_len": "\(bytes.count)"],
                     startedAt: start)
    }

    private func paste(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        harness.focus(rec.pane)
        let text = "붙여넣기 테스트 가나다\nsecond line"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let mark = rec.log.mark()
        if let key = Synth.command("v") { Synth.press(key, in: window) }
        let bytes = await harness.settledBytes(rec.log, since: mark, expectingAtLeast: text.utf8.count)
        let carriage = Hex.bytes(text.replacingOccurrences(of: "\n", with: "\r"))
        let ok = bytes == carriage || bytes == Hex.bytes(text)
        return .make("IN-07", "붙여넣기 중복 0·원문 보존",
                     status: ok ? .pass : .fail,
                     evidence: ["hex": Hex.string(bytes)], startedAt: start)
    }

    private func escapeKey(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        harness.focus(rec.pane)
        let mark = rec.log.mark()
        Synth.press(Synth.escape, in: window)
        let bytes = await harness.settledBytes(rec.log, since: mark)
        return .make("IN-10", "Esc → 1b",
                     status: bytes == [0x1b] ? .pass : .fail,
                     evidence: ["hex": Hex.string(bytes)], startedAt: start)
    }

    private func commandKeysDoNotLeak(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        harness.focus(rec.pane)
        let mark = rec.log.mark()
        if let copy = Synth.command("c") { Synth.press(copy, in: window) }
        await harness.pause(.milliseconds(300))
        let bytes = rec.log.bytes(since: mark)
        return .make("IN-11", "선택 없을 때 ⌘C가 PTY로 새지 않음",
                     status: bytes.isEmpty ? .pass : .fail,
                     evidence: ["hex": Hex.string(bytes)], startedAt: start)
    }

    // MARK: - IME callback contract (scripted IMK)

    private func contractHangulWithSpace(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> TestResult {
        let steps = keys("rksk", ime: [
            [.setMarkedText("ㄱ")], [.setMarkedText("가")],
            [.setMarkedText("간")], [.insertText("가"), .setMarkedText("나")],
        ]) + [(key: Synth.space, ime: [.insertText("나"), .insertText(" ")])]
        return await replay("IN-01", "한글 조합 확정 1회·조합 중 무전송·이어지는 스페이스 0x20",
                            steps: steps, expected: "가나 ", rec, window)
    }

    private func contractBackspaceWhileComposing(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> TestResult {
        let steps = keys("rks", ime: [[.setMarkedText("ㄱ")], [.setMarkedText("가")], [.setMarkedText("간")]])
            + [(key: Synth.delete, ime: [.setMarkedText("가")]),
               (key: Synth.space, ime: [.insertText("가"), .insertText(" ")])]
        return await replay("IN-02", "조합 중 Backspace는 조합만 수정",
                            steps: steps, expected: "가 ", rec, window)
    }

    private func replay(
        _ id: String, _ title: String, steps: [Step], expected: String,
        _ rec: SelfTestHarness.RecorderPane, _ window: NSWindow
    ) async -> TestResult {
        let start = ContinuousClock.now
        guard let probe = rec.pane.probeView else { return setupFailure("probe view missing", start) }
        harness.focus(rec.pane)
        probe.clearReplayQueue()
        let mark = rec.log.mark()
        var leakedWhileComposing: [UInt8] = []
        for (index, step) in steps.enumerated() {
            probe.enqueueReplay(step.ime)
            Synth.press(step.key, in: window)
            if index < steps.count - 1, probe.hasMarkedText() {
                await harness.pause(.milliseconds(40))
                leakedWhileComposing = rec.log.bytes(since: mark)
            }
        }
        let bytes = await harness.settledBytes(rec.log, since: mark, expectingAtLeast: expected.utf8.count)
        let ok = bytes == Hex.bytes(expected) && probe.pendingReplayCount == 0
        probe.clearReplayQueue()
        return .make(id, title, status: ok ? .pass : .fail, layer: .imeCallbackContract,
                     evidence: ["hex": Hex.string(bytes), "expected": Hex.string(Hex.bytes(expected)),
                                "leaked_before_commit": Hex.string(leakedWhileComposing)],
                     startedAt: start)
    }

    private func paneSwitchWhileComposing(
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
        harness.focus(second.pane)
        await harness.pause(.milliseconds(300))
        Synth.type("x", in: window)
        let bytesB = await harness.settledBytes(second.log, since: markB)
        let bytesA = first.log.bytes(since: markA)
        let okA = bytesA.isEmpty || bytesA == Hex.bytes("ㄱ")
        return .make("IN-04", "조합 중 pane 전환 시 오배달 0",
                     status: okA && bytesB == [0x78] ? .pass : .fail, layer: .imeCallbackContract,
                     evidence: ["pane_a": Hex.string(bytesA), "pane_b": Hex.string(bytesB)],
                     startedAt: start)
    }

    // MARK: - Synthetic events through the real input method

    private func syntheticKoreanPath(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        guard let probe = rec.pane.probeView else { return setupFailure("probe view missing", start) }
        let selected = InputSourceGuard.select(id: InputSourceGuard.korean2Set)
        defer { InputSourceGuard.restore() }
        harness.focus(rec.pane)
        probe.clearReplayQueue()
        probe.clearCallLog()
        let mark = rec.log.mark()
        Synth.type("rksk ", in: window)
        let bytes = await harness.settledBytes(rec.log, since: mark)
        let imkEngaged = probe.callLog.contains { $0.kind == .setMarkedText }
        saveCallLog(probe.callLog, name: "synthetic-korean-calllog.json")
        let verdict = syntheticVerdict(selected: selected, engaged: imkEngaged, bytes: bytes)
        return .make("IN-01-syn", "합성 이벤트 → 실제 입력기 경유 한글 조합",
                     status: verdict, layer: .syntheticEventPath,
                     evidence: ["input_source_selected": "\(selected)", "imk_engaged": "\(imkEngaged)",
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

    // MARK: - Ctrl+C

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
        return .make("IN-09", "Ctrl+C → foreground 프로세스 그룹 SIGINT",
                     status: hit ? .pass : .fail, startedAt: start)
    }

    // MARK: - Helpers

    private func keys(_ letters: String, ime: [[ScriptedIMECall]]) -> [Step] {
        zip(letters, ime).compactMap { letter, calls in
            Synth.key(letter).map { (key: $0, ime: calls) }
        }
    }

    private func saveCallLog(_ log: [InputCallRecord], name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(log) else { return }
        try? data.write(to: harness.outputDirectory.appendingPathComponent(name))
    }

    private func setupFailure(_ reason: String, _ start: ContinuousClock.Instant) -> TestResult {
        .make("IN-setup", "입력 스위트 준비", status: .fail, cause: .app,
              evidence: ["reason": reason], startedAt: start)
    }
}
