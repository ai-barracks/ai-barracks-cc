import AppKit
import Carbon.HIToolbox

/// "정리하고 닫기" (2026-11-24: X hangs an agent up before the barrack's
/// session-end protocol; aib closes the record but nobody writes the wiki).
/// The rule, typing into recorder panes that stand in for agents (aib state
/// is passed in, never a real agent), and ⌘⇧W from a focused terminal.
@MainActor
struct WrapUpTests {
    let harness: SelfTestHarness

    func run() async -> [TestResult] {
        [await typesAndCloses(), await shortcutReachesMenu()]
    }

    /// WU-01a: when a pending wrap-up closes, waits, or gives up.
    static func rule() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let asked = Date(timeIntervalSince1970: 1_000_000)
        let wrapUp = WrapUp(paneID: UUID(), barrackID: "b", requestedAt: asked)
        let session = { (state: Liveness, ts: Int) in
            LiveSession(id: "s", state: state, ageSeconds: 0, pid: 1, cwd: nil, runID: "one-run", updatedAt: ts)
        }
        let cases: [(String, LiveSession?, Bool, TimeInterval, WrapUpRule.Decision)] = [
            ("finish before the request", session(.done, 999_999), false, 5, .wait),
            ("finish in the request's second", session(.done, 1_000_000), false, 5, .wait),
            ("turn running", session(.working, 1_000_003), false, 5, .wait),
            ("permission prompt mid wrap-up", session(.blocked, 1_000_003), false, 5, .wait),
            ("finished 1 s ago (Stop hooks still running)", session(.done, 1_000_004), false, 5, .wait),
            ("turn finished", session(.done, 1_000_004), false, 4 + TimeInterval(AppConstants.WrapUp.settleSeconds), .close),
            ("finished and already seen", session(.idle, 1_000_004), false, 30, .close),
            ("no aib state yet", nil, false, 60, .wait),
            ("terminal gone", session(.done, 1_000_004), true, 5, .forget),
            ("never finished", session(.working, 1_000_003), false, AppConstants.WrapUp.timeout + 1, .expire),
        ]
        for (name, live, gone, after, expected) in cases {
            let got = WrapUpRule.decide(wrapUp, session: live, paneGone: gone, now: asked.addingTimeInterval(after))
            if got != expected { failures.append("\(name): \(got) ≠ \(expected)") }
        }
        failures += readsTimestamp()
        let fold = { (event: String) in
            Liveness.fold(state: "working", event: event, statusTimestamp: 0, runID: "r", ack: nil, now: 5, pid: .alive, staleAfter: 180)
        }
        let fresh = LiveSession(id: "s", state: fold("SessionStart"), ageSeconds: 5, pid: 1, cwd: nil, event: "SessionStart")
        let tool = LiveSession(id: "s", state: fold("PreToolUse"), ageSeconds: 5, pid: 1, cwd: nil, event: "PreToolUse")
        if fresh.isMidTurn || !tool.isMidTurn { failures.append("SessionStart working counted as mid-turn (or a tool not)") }
        if AppConstants.WrapUp.request.contains("\n") || !AppConstants.WrapUp.request.hasPrefix("끝") {
            failures.append("request must be one line starting with 끝")
        }
        if !AppConstants.Terminal.appReservedChords.contains("super+shift+w") { failures.append("⌘⇧W left to Ghostty") }
        let w = UInt16(kVK_ANSI_W)
        let chords: [(UInt16, NSEvent.ModifierFlags, Bool)] = [
            (w, [.command, .shift], true), (w, [.command, .shift, .capsLock], true), (w, [.command], false),
            (w, [.command, .shift, .option], false), (UInt16(kVK_ANSI_Q), [.command, .shift], false),
        ]
        let wrapUpKey = ShortcutAction.wrapUp.defaultChord
        for (code, flags, expected) in chords where (KeyChord(keyCode: code, flags: flags) == wrapUpKey) != expected {
            failures.append("chord \(code) \(flags.rawValue) → \(!expected)")
        }
        return .make("WU-01a", "정리하고 닫기 판정: 요청 뒤에 끝난 턴만, 끝난 지 3초 뒤 닫음(입력 대기·작업 중은 기다림), 터미널이 없어지면 잊고 30분 넘으면 포기, ⌘⇧W는 키 위치로",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// The reader keeps the status file's `ts` (aib reuses one run_id).
    private static func readsTimestamp() -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-wu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = directory.appendingPathComponent("sessions/.live")
        try? FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let body: [String: Any] = ["session_id": "s", "state": "done", "ts": 1_234_567, "pid": 1, "run_id": "r", "event": "Stop"]
        if let data = try? JSONSerialization.data(withJSONObject: body) { try? data.write(to: live.appendingPathComponent("s.status")) }
        let read = LivenessReader.read(barrackPath: directory.path).first
        return read?.updatedAt == 1_234_567 && read?.event == "Stop" ? [] : ["status read as \(read.map { "\($0.updatedAt) \($0.event)" } ?? "nil")"]
    }

    /// WU-01b: shells and busy agents get nothing typed; an idle agent gets
    /// the one-line request, then Enter on its own; it closes when a later
    /// turn finishes, not while it waits for the user; asking again calls
    /// the close off; without aib state it is typed but never closed.
    private func typesAndCloses() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        var failures: [String] = []
        guard let shell = harness.makeRecorderPane(name: "wu-shell"),
              let agent = harness.makeRecorderPane(name: "wu-agent", agent: .claude),
              let other = harness.makeRecorderPane(name: "wu-other", agent: .codex)
        else { return Self.fail("WU-01b", "setup", start) }
        await harness.install([shell.pane, agent.pane, other.pane], layout: .quad)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { shell.log.isReady && agent.log.isReady && other.log.isReady }
        let now = Int(Date().timeIntervalSince1970)
        let live = { (state: Liveness, ts: Int) in
            LiveSession(id: "s", state: state, ageSeconds: 0, pid: 1, cwd: nil, updatedAt: ts, event: "PreToolUse")
        }
        // What LivenessReader makes of SessionStart's `working`.
        let freshState = Liveness.fold(state: "working", event: "SessionStart", statusTimestamp: now - 5, runID: "r",
                                       ack: nil, now: now, pid: .alive, staleAfter: LivenessReader.staleAfter)
        let fresh = LiveSession(id: "s", state: freshState, ageSeconds: 5, pid: 1, cwd: nil, updatedAt: now - 5, event: "SessionStart")
        let request = Array(AppConstants.WrapUp.request.utf8)

        let shellMark = shell.log.mark()
        if workspace.startWrapUp(of: shell.pane, current: .some(nil)) != .refused { failures.append("shell not refused") }
        let agentMark = agent.log.mark()
        if workspace.startWrapUp(of: agent.pane, current: live(.working, now)) != .refused { failures.append("working not refused") }
        if workspace.startWrapUp(of: agent.pane, current: live(.blocked, now)) != .refused { failures.append("blocked not refused") }
        await harness.pause(.milliseconds(600))
        if !shell.log.bytes(since: shellMark).isEmpty || !agent.log.bytes(since: agentMark).isEmpty { failures.append("typed while refused") }

        if workspace.startWrapUp(of: agent.pane, current: live(.done, now - 30)) != .started { failures.append("idle agent not started") }
        await harness.pause(.milliseconds(150))
        let early = agent.log.bytes(since: agentMark)
        let typed = await harness.settledBytes(agent.log, since: agentMark, expectingAtLeast: request.count + 1)
        if early.contains(0x0D) { failures.append("Enter came with the text") }
        if typed != request + [0x0D] { failures.append("typed \(typed.count) bytes, tail \(Hex.string(Array(typed.suffix(8))))") }

        let later = now + 5
        let settled = Date(timeIntervalSince1970: TimeInterval(later + AppConstants.WrapUp.settleSeconds + 1))
        workspace.checkWrapUps(now: settled) { _ in live(.blocked, later) }
        if !workspace.panes.contains(where: { $0.id == agent.pane.id }) { failures.append("closed while waiting for the user") }
        workspace.checkWrapUps(now: Date(timeIntervalSince1970: TimeInterval(later + 1))) { _ in live(.done, later) }
        if !workspace.panes.contains(where: { $0.id == agent.pane.id }) { failures.append("closed before the finish settled") }
        workspace.checkWrapUps(now: settled) { _ in live(.done, later) }
        if workspace.panes.contains(where: { $0.id == agent.pane.id }) || !workspace.wrapUps.isEmpty { failures.append("not closed after the turn") }

        if workspace.startWrapUp(of: other.pane, current: fresh) != .started { failures.append("fresh agent (SessionStart working) not started") }
        if workspace.toggleWrapUp(of: other.pane) != .cancelled || !workspace.wrapUps.isEmpty { failures.append("asking again did not call off") }
        workspace.checkWrapUps(now: settled) { _ in live(.done, later) }
        if !workspace.panes.contains(where: { $0.id == other.pane.id }) { failures.append("closed after call-off") }
        if workspace.startWrapUp(of: other.pane, current: .some(nil)) != .sentWithoutClose || !workspace.wrapUps.isEmpty {
            failures.append("no aib state: not typed-only")
        }
        await harness.pause(AppConstants.WrapUp.submitDelay + .milliseconds(200))
        return .make("WU-01b", "정리하고 닫기: 셸·작업 중·입력 대기에는 입력 안 함(막 시작한 에이전트는 보냄), 한 줄 요청 뒤 Enter 따로, 다음 턴이 끝나고 3초 뒤 닫음(입력 대기 중엔 유지), 다시 누르면 닫지 않음, aib 상태 없으면 입력만",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// WU-01c: ⌘⇧W in a focused agent terminal reaches the menu (not
    /// Ghostty's close_window, not the PTY) and types the request there.
    /// Events carry the characters each keyboard layout gives (CGEvent):
    /// a hand-made one with Shift but charactersIgnoringModifiers "w" was
    /// taken by File > 닫기 (⌘W). The Korean layout run is calibrated with
    /// ⌘K (the palette), which works for people typing Korean.
    private func shortcutReachesMenu() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        guard let agent = harness.makeRecorderPane(name: "wu-key", agent: .claude), let window = harness.window,
              let ascii = InputSourceGuard.asciiCandidates.first(where: { InputSourceGuard.select(id: $0) })
        else { return Self.fail("WU-01c", "setup", start) }
        await harness.install([agent.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { agent.log.isReady }
        let request = Array(AppConstants.WrapUp.request.utf8)
        var evidence = ["menu_w": Self.menuItems(key: "w").joined(separator: "; ")]
        var missed: [String] = []
        for (name, source) in [("ascii", ascii), ("korean", InputSourceGuard.korean2Set)] {
            let outcome = await InputSourceGuard.with(source) { () -> String in
                harness.focus(agent.pane)
                guard let palette = Self.layoutChord(UInt16(kVK_ANSI_K), [.maskCommand], [.command]),
                      let chord = Self.layoutChord(UInt16(kVK_ANSI_W), [.maskCommand, .maskShift], [.command, .shift])
                else { return "no event" }
                EventSynthesizer.press(palette, in: window)
                let opened = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { workspace.isPalettePresented }
                if opened {
                    await harness.settleSheet(shown: true)
                    workspace.isPalettePresented = false
                    await harness.settleSheet(shown: false)
                }
                harness.focus(agent.pane)
                let mark = agent.log.mark()
                EventSynthesizer.press(chord, in: window)
                let typed = await harness.settledBytes(agent.log, since: mark, expectingAtLeast: request.count + 1)
                if typed != request + [0x0D] || !window.isVisible { missed.append(name) }
                let calls = (agent.pane.probeView?.callLog.suffix(4) ?? []).map { "\($0.kind.rawValue):\($0.text ?? "")" }
                return "⌘K \(palette.unmodified) palette=\(opened); ⌘⇧W \(chord.characters)/\(chord.unmodified) typed=\(typed.count)/\(request.count + 1) window=\(window.isVisible) calls=\(calls)"
            }
            evidence[name] = outcome ?? "source missing"
        }
        await harness.pause(AppConstants.WrapUp.submitDelay + .milliseconds(200))
        return .make("WU-01c", "터미널 포커스에서 ⌘⇧W → 정리 요청 입력(영문·한글 입력 상태 모두, Ghostty 창 닫기·PTY로 새지 않음)",
                     status: missed.isEmpty && evidence["korean"] != "source missing" ? .pass : .fail, cause: .app,
                     evidence: evidence.merging(["missed": missed.joined(separator: ",")]) { $1 }, startedAt: start)
    }

    /// A ⌘ key as the current keyboard layout reports it. AppKit derives
    /// charactersIgnoringModifiers from the key code, layout and Shift; a
    /// CGEvent's own string is fixed when it is made (before the flags), so
    /// `characters` takes the derived value too, as with a real ⌘ key.
    private static func layoutChord(_ code: UInt16, _ flags: CGEventFlags, _ modifiers: NSEvent.ModifierFlags) -> EventSynthesizer.Key? {
        guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true) else { return nil }
        cg.flags = flags
        guard let plain = NSEvent(cgEvent: cg)?.charactersIgnoringModifiers else { return nil }
        return EventSynthesizer.Key(keyCode: code, characters: plain, unmodified: plain, modifiers: modifiers)
    }

    /// Every main-menu item bound to `key` (any case), with its modifiers:
    /// a menu earlier in the bar wins the same chord.
    private static func menuItems(key: String) -> [String] {
        func walk(_ menu: NSMenu?, _ path: String) -> [String] {
            (menu?.items ?? []).flatMap { item -> [String] in
                let here = path.isEmpty ? item.title : "\(path) > \(item.title)"
                let own = item.keyEquivalent.lowercased() == key
                    ? ["\(here) [\(item.keyEquivalent) \(item.keyEquivalentModifierMask.rawValue)]"] : []
                return own + walk(item.submenu, here)
            }
        }
        return walk(NSApp.mainMenu, "")
    }

    private static func fail(_ id: String, _ reason: String, _ start: ContinuousClock.Instant) -> TestResult {
        .make(id, "정리하고 닫기", status: .fail, cause: .app, evidence: ["reason": reason], startedAt: start)
    }
}
