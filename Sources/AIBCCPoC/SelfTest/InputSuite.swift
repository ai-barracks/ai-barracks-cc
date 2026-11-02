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
            await commandKDoesNotLeak(primary, window),
            await contractHangulWithSpace(primary, window),
            await contractBackspaceWhileComposing(primary, window),
            await paneClickWhileComposing(primary, secondary, window),
            await syntheticKoreanPath(primary, window),
        ]
        return measured + [await bracketedPaste(window), await controlC(window), await quadCore(window)]
    }

    /// ST-01b: the core input checks (space byte, Hangul composition
    /// contract, paste) repeated in every pane of a 2x2 grid, each pane
    /// focused through a real click.
    private func quadCore(_ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        let recorders = (1...4).compactMap { harness.makeRecorderPane(name: "quadcore-\($0)") }
        guard recorders.count == 4 else { return setupFailure("quad recorders", start) }
        await harness.install(recorders.map(\.pane), layout: .quad)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorders.allSatisfy { $0.log.isReady } }
        var failures: [String] = []
        for (index, rec) in recorders.enumerated() {
            // Routing is judged right after the real click, before any helper
            // re-focuses the pane (Codex review r3 #3).
            await harness.click(row: 3, column: 2, in: rec.pane)
            if !harness.isFirstResponder(rec.pane.probeView) {
                failures = failures + ["pane\(index + 1):click-not-routed"]
            }
            let others = recorders.enumerated().filter { $0.offset != index }
            let marks = others.map { $0.element.log.mark() }
            let checks = [
                await spaceKey(rec, window),
                await contractHangulWithSpace(rec, window),
                await paste("ST-01b-paste", "", text: "붙여넣기 \(index + 1)", rec, window),
            ]
            failures = failures + checks.filter { $0.status != .pass }.map { "pane\(index + 1):\($0.id)" }
            let leaked = zip(others, marks).filter { !$0.0.element.log.bytes(since: $0.1).isEmpty }
            failures = failures + leaked.map { "pane\($0.0.offset + 1):leak-from-pane\(index + 1)" }
        }
        return .make("ST-01b", "4분할 각 pane: 스페이스·한글 조합 계약·붙여넣기",
                     status: failures.isEmpty ? .pass : .fail,
                     evidence: ["failures": failures.joined(separator: ", ")], startedAt: start)
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
        let trace = rec.pane.probeView?.callLog.suffix(6).map { "\($0.kind.rawValue):\($0.text ?? "")" } ?? []
        let direct = bytes.isEmpty ? await directPasteAction(rec) : []
        return .make(id, title, status: bytes == expected ? .pass : .fail,
                     evidence: ["hex": Hex.string(bytes), "expected": Hex.string(expected),
                                "probe_trace": trace.joined(separator: " | "),
                                "direct_paste_action_hex": Hex.string(direct),
                                "menu_cmd_v": menuItemDescription(for: "v")],
                     startedAt: start)
    }

    /// Diagnosis: which main-menu item owns a Cmd+<key> equivalent.
    private func menuItemDescription(for key: String) -> String {
        func search(_ menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            for item in menu.items {
                if item.keyEquivalent == key, item.keyEquivalentModifierMask == .command { return item }
                if let found = search(item.submenu) { return found }
            }
            return nil
        }
        guard let item = search(NSApp.mainMenu) else { return "none" }
        let action = item.action.map(NSStringFromSelector) ?? "nil"
        return "\(item.title) action=\(action) target=\(item.target.map { String(describing: type(of: $0)) } ?? "nil") enabled=\(item.isEnabled)"
    }

    /// Diagnosis: invoke the view's paste action directly (what Edit > Paste
    /// does) to separate "Cmd+V never arrived" from "Ghostty paste path".
    private func directPasteAction(_ rec: SelfTestHarness.RecorderPane) async -> [UInt8] {
        let mark = rec.log.mark()
        rec.pane.probeView?.paste(nil)
        return await harness.settledBytes(rec.log, since: mark)
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
        await harness.drain()
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
        await harness.drain()
        await harness.pause(.milliseconds(300))
        let bytes = rec.log.bytes(since: mark)
        return .make("IN-11b", "앱 단축키(⌥⌘I)가 동작하고 PTY로 새지 않음",
                     status: toggled && bytes.isEmpty ? .pass : .fail,
                     evidence: ["menu_handled": "\(toggled)", "hex": Hex.string(bytes)], startedAt: start)
    }

    /// IN-11c: ⌘K (command palette in the product) must not inject bytes.
    private func commandKDoesNotLeak(_ rec: SelfTestHarness.RecorderPane, _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        harness.focus(rec.pane)
        let mark = rec.log.mark()
        if let key = Synth.command("k") { Synth.press(key, in: window) }
        await harness.drain()
        await harness.pause(.milliseconds(300))
        let bytes = rec.log.bytes(since: mark)
        // ⌘K is the palette (v1 parity); close it so later keys reach the pane.
        let opened = harness.workspace.isPalettePresented
        harness.workspace.isPalettePresented = false
        await harness.pause(.milliseconds(400))
        harness.focus(rec.pane)
        return .make("IN-11c", "⌘K는 명령 팔레트를 열고 PTY로 바이트를 보내지 않음",
                     status: bytes.isEmpty && opened ? .pass : .fail,
                     evidence: ["hex": Hex.string(bytes), "palette": "\(opened)"], startedAt: start)
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
        // The scripted IME never commits; drop A's leftover composition so it
        // cannot leak into the next test.
        if probe.hasMarkedText() { probe.unmarkText() }
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

    /// IN-08a: with bracketed paste on, an embedded end marker must be
    /// neutralized and every other byte preserved. Accepted neutralizations:
    /// drop the inner marker, or drop only its ESC; newlines as LF or CR.
    private func bracketedPaste(_ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        guard let rec = harness.makeRecorderPane(name: "bracketed", environment: ["AIBCC_BRACKETED_PASTE": "1"]),
              let key = Synth.command("v")
        else { return setupFailure("bracketed fixture missing", start) }
        await harness.install([rec.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { rec.log.isReady }
        harness.focus(rec.pane)
        let payload = "abc\u{1b}[201~rm -rf x\ndef"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        let mark = rec.log.mark()
        Synth.press(key, in: window)
        let bytes = await harness.settledBytes(rec.log, since: mark, expectingAtLeast: 12)
        let accepted = acceptedBracketedPastes(payload)
        return .make("IN-08a", "bracketed paste: 내부 종료 구분자 무력화·나머지 원문 보존",
                     status: accepted.contains(bytes) ? .pass : .fail,
                     evidence: ["hex": Hex.string(bytes),
                                "accepted": accepted.map(Hex.string).joined(separator: " || ")],
                     startedAt: start)
    }

    /// Policy fixed after the first real run (2026-10-31): Ghostty replaces
    /// the ESC of an embedded end marker with a space, keeps LF inside a
    /// bracketed paste, and appends exactly one real end marker.
    private func acceptedBracketedPastes(_ payload: String) -> [[UInt8]] {
        let marker = "\u{1b}[201~"
        let neutralized = [payload.replacingOccurrences(of: marker, with: " [201~"),
                           payload.replacingOccurrences(of: marker, with: ""),
                           payload.replacingOccurrences(of: marker, with: "[201~")]
        let newlineForms = neutralized.flatMap { [$0, $0.replacingOccurrences(of: "\n", with: "\r")] }
        return newlineForms.map { Hex.bytes("\u{1b}[200~" + $0 + marker) }
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
        // Let the pane swap's pending events (old surface teardown) drain
        // before pressing; record focus so a lost key can be attributed.
        await harness.drain()
        let focusedBeforePress = harness.isFirstResponder(pane.probeView)
        Synth.press(key, in: window)
        let hit = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            FileManager.default.fileExists(atPath: signalled.path)
        }
        let trace = pane.probeView?.callLog.suffix(8).map { "\($0.kind.rawValue):\($0.text ?? "")" } ?? []
        return .make("IN-09a", "Ctrl+C → foreground 프로세스 그룹 SIGINT (trap 실행)",
                     status: hit ? .pass : .fail,
                     evidence: ["probe_trace": trace.joined(separator: " | "),
                                "focused_before_press": "\(focusedBeforePress)"], startedAt: start)
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
        try? data.write(to: harness.outputDirectory.appendingPathComponent(name), options: .atomic)
    }

    private func setupFailure(_ reason: String, _ start: ContinuousClock.Instant) -> TestResult {
        .make("IN-setup", "입력 스위트 준비", status: .fail, cause: .app,
              evidence: ["reason": reason], startedAt: start)
    }
}
