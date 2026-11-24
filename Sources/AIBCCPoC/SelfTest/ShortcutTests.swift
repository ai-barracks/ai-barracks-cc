import AppKit
import Carbon.HIToolbox

/// Settable shortcuts (2026-11-24, user: "단축키가 있으면 편할 기능들에
/// 단축키를 설정 가능하도록"). The store's rules against a scratch
/// UserDefaults, then the real window: a changed key works in English and
/// Korean input, the old one stops, the recorder takes keys without acting.
@MainActor
struct ShortcutTests {
    let harness: SelfTestHarness

    /// KB-01a: defaults are distinct ⌘ keys none of which macOS or the app
    /// already use; assign refuses ⌘-less, reserved and taken keys; clear,
    /// reset (refused when the default is taken), reset all; kept across
    /// a new store; names; event flags.
    static func rules() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let defaults = ShortcutAction.allCases.compactMap(\.defaultChord)
        if Set(defaults).count != defaults.count { failures.append("duplicate defaults") }
        for action in ShortcutAction.allCases {
            guard let chord = action.defaultChord else { continue }
            if !chord.modifiers.contains(.command) || ShortcutStore.reserved[chord] != nil || chord.keyboardShortcut == nil {
                failures.append("default \(action.rawValue) \(chord.display)")
            }
        }
        let suite = "aibcc-kb-\(UUID().uuidString)"
        guard let scratch = UserDefaults(suiteName: suite) else { return check("KB-01a", ["no scratch defaults"], start) }
        defer { scratch.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(defaults: scratch)
        let commandShiftP = KeyChord(kVK_ANSI_P, [.command, .shift])
        let expectations: [(String, ShortcutStore.Problem?, ShortcutStore.Problem?)] = [
            ("no ⌘", store.assign(KeyChord(kVK_ANSI_P, .option), to: .palette), .needsCommand),
            ("⌘Q", store.assign(KeyChord(kVK_ANSI_Q, .command), to: .palette), .reserved("종료")),
            ("⌘V", store.assign(KeyChord(kVK_ANSI_V, .command), to: .palette), .reserved("붙여넣기")),
            ("taken ⌘N", store.assign(KeyChord(kVK_ANSI_N, .command), to: .palette), .taken(.newAgent)),
            ("escape", store.assign(KeyChord(kVK_Escape, .command), to: .palette), .unknownKey),
            ("⌘⇧P", store.assign(commandShiftP, to: .palette), nil),
            ("same key again", store.assign(commandShiftP, to: .palette), nil),
        ]
        for (name, got, expected) in expectations where got != expected { failures.append("\(name): \(String(describing: got))") }
        if store.action(for: commandShiftP) != .palette || store.action(for: KeyChord(kVK_ANSI_K, .command)) != nil {
            failures.append("lookup after change")
        }
        // ⌘K is free now: another action may take it, and then palette's
        // reset is refused instead of making two actions share a key.
        store.assign(KeyChord(kVK_ANSI_K, .command), to: .closeTerminal)
        if store.reset(.palette) != .taken(.closeTerminal) { failures.append("reset onto a taken key") }
        if ShortcutStore(defaults: scratch).chord(for: .palette) != commandShiftP { failures.append("not kept across launches") }
        store.clear(.wrapUp)
        if store.chord(for: .wrapUp) != nil || store.action(for: KeyChord(kVK_ANSI_W, [.command, .shift])) != nil {
            failures.append("clear")
        }
        store.resetAll()
        if ShortcutAction.allCases.contains(where: { store.chord(for: $0) != $0.defaultChord }) || !store.overrides.isEmpty {
            failures.append("reset all")
        }
        if KeyChord(kVK_ANSI_W, [.command, .shift]).display != "⇧⌘W"
            || KeyChord(kVK_DownArrow, [.command, .option]).display != "⌥⌘↓" {
            failures.append("display \(KeyChord(kVK_ANSI_W, [.command, .shift]).display)")
        }
        if KeyChord(keyCode: UInt16(kVK_ANSI_W), flags: [.command, .shift, .capsLock, .function]) != KeyChord(kVK_ANSI_W, [.command, .shift]) {
            failures.append("caps lock / fn counted")
        }
        if KeyChord(stored: KeyChord(kVK_ANSI_K, [.command, .control]).stored) != KeyChord(kVK_ANSI_K, [.command, .control]) {
            failures.append("stored round trip")
        }
        return check("KB-01a", failures, start, title: "단축키 규칙: 기본값 중복·예약 키 없음, ⌘ 없는·예약·이미 쓰는 키 거부, 지우기·기본값(겹치면 거부)·모두 기본값, 재실행 뒤 유지, 표기")
    }

    func run() async -> [TestResult] {
        [await changedKeyWorks(), await movesAround()]
    }

    /// KB-01b: palette moved to ⌘⇧P opens with ⌘⇧P under English and
    /// Korean input, ⌘K stops opening it; the recorder gets the next key
    /// (Esc = cancel) and nothing runs; back to default, ⌘K opens it.
    private func changedKeyWorks() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        let store = ShortcutStore.shared
        var failures: [String] = []
        guard let recorder = harness.makeRecorderPane(name: "kb"), let window = harness.window,
              let ascii = InputSourceGuard.asciiCandidates.first(where: { InputSourceGuard.select(id: $0) })
        else { return Self.check("KB-01b", ["setup"], start) }
        await harness.install([recorder.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorder.log.isReady }
        let saved = store.overrides
        defer { store.restore(saved) }
        store.assign(KeyChord(kVK_ANSI_P, [.command, .shift]), to: .palette)
        for (name, source) in [("ascii", ascii), ("korean", InputSourceGuard.korean2Set)] {
            let outcome = await InputSourceGuard.with(source) { () -> String in
                let opened = await opens(code: kVK_ANSI_P, [.maskCommand, .maskShift], [.command, .shift], recorder.pane, window)
                let old = await opens(code: kVK_ANSI_K, [.maskCommand], [.command], recorder.pane, window)
                return opened && !old ? "" : "⌘⇧P \(opened), ⌘K \(old)"
            }
            if outcome != "" { failures.append("\(name): \(outcome ?? "source missing")") }
        }
        // The recorder takes the key; nothing runs, nothing reaches the PTY.
        var recorded: [KeyChord?] = []
        let mark = recorder.log.mark()
        ShortcutCenter.recorder = { recorded.append($0) }
        harness.focus(recorder.pane)
        if let key = Self.key(kVK_ANSI_P, [.maskCommand, .maskShift], [.command, .shift]) { EventSynthesizer.press(key, in: window) }
        _ = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { !recorded.isEmpty }
        ShortcutCenter.recorder = { recorded.append($0) }
        EventSynthesizer.press(EventSynthesizer.escape, in: window)
        _ = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { recorded.count == 2 }
        ShortcutCenter.recorder = nil
        await harness.pause(.milliseconds(300))
        if recorded != [KeyChord(kVK_ANSI_P, [.command, .shift]), nil] { failures.append("recorded \(recorded.map { $0?.display ?? "esc" })") }
        if workspace.isPalettePresented || !recorder.log.bytes(since: mark).isEmpty { failures.append("recording acted or leaked") }
        store.reset(.palette)
        if !(await opens(code: kVK_ANSI_K, [.maskCommand], [.command], recorder.pane, window)) { failures.append("⌘K after reset") }
        return Self.check("KB-01b", failures, start, title: "바꾼 단축키(명령·검색 ⌘⇧P)가 영문·한글 입력 모두에서 동작, 옛 키(⌘K)는 멈춤, 녹음 중 키는 녹음만(Esc 취소, 실행·PTY 없음), 기본값 복귀")
    }

    /// KB-01c: ⌘3 shows History, ⌘2 Agents; ⌘⌥2 splits; ⌘] moves focus
    /// to the other slot; ⌘⌥L hides and shows the agent list.
    private func movesAround() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        var failures: [String] = []
        guard let a = harness.makeRecorderPane(name: "kb-a"), let b = harness.makeRecorderPane(name: "kb-b"),
              let window = harness.window, InputSourceGuard.selectASCIIBaseline() != nil
        else { return Self.check("KB-01c", ["setup"], start) }
        await harness.install([a.pane, b.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { a.log.isReady }
        harness.focus(a.pane)
        let press = { (code: Int, flags: CGEventFlags, modifiers: NSEvent.ModifierFlags) in
            if let key = Self.key(code, flags, modifiers) { EventSynthesizer.press(key, in: window) }
        }
        press(kVK_ANSI_3, .maskCommand, .command)
        if !(await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { workspace.destination == .history }) { failures.append("⌘3 → \(workspace.destination)") }
        press(kVK_ANSI_2, .maskCommand, .command)
        if !(await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { workspace.destination == .sessions }) { failures.append("⌘2 → \(workspace.destination)") }
        _ = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { a.pane.probeView?.window != nil }
        harness.focus(a.pane)
        press(kVK_ANSI_2, [.maskCommand, .maskAlternate], [.command, .option])
        if !(await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { workspace.layout == .double }) { failures.append("⌘⌥2 → \(workspace.layout)") }
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { b.pane.probeView?.window != nil }
        harness.focus(a.pane)
        press(kVK_ANSI_RightBracket, .maskCommand, .command)
        if !(await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { harness.isFirstResponder(b.pane.probeView) }) { failures.append("⌘] focus") }
        let listKey = AppConstants.Terminal.agentListShownKey
        let before = UserDefaults.standard.object(forKey: listKey) as? Bool ?? true
        press(kVK_ANSI_L, [.maskCommand, .maskAlternate], [.command, .option])
        let toggled = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            (UserDefaults.standard.object(forKey: listKey) as? Bool ?? true) != before
        }
        if !toggled { failures.append("⌘⌥L") }
        UserDefaults.standard.set(before, forKey: listKey)
        let leaked = a.log.bytes(since: 0).filter { $0 == 0x5D || $0 == 0x33 }
        if !leaked.isEmpty { failures.append("keys reached the PTY") }
        workspace.setLayout(.single)
        return Self.check("KB-01c", failures, start, title: "기본 단축키: ⌘3 History·⌘2 Agents, ⌘⌥2 좌우 분할, ⌘] 다음 칸 포커스, ⌘⌥L 에이전트 목록, PTY로 새지 않음")
    }

    /// Opens the palette with the key? Closes it again.
    private func opens(code: Int, _ flags: CGEventFlags, _ modifiers: NSEvent.ModifierFlags,
                       _ pane: TerminalPane, _ window: NSWindow) async -> Bool {
        harness.focus(pane)
        guard let key = Self.key(code, flags, modifiers) else { return false }
        EventSynthesizer.press(key, in: window)
        let opened = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { harness.workspace.isPalettePresented }
        if opened {
            await harness.settleSheet(shown: true)
            harness.workspace.isPalettePresented = false
            await harness.settleSheet(shown: false)
        }
        return opened
    }

    /// A key with the characters the current layout gives it (cf. WU-01c).
    static func key(_ code: Int, _ flags: CGEventFlags, _ modifiers: NSEvent.ModifierFlags) -> EventSynthesizer.Key? {
        guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true) else { return nil }
        cg.flags = flags
        guard let plain = NSEvent(cgEvent: cg)?.charactersIgnoringModifiers else { return nil }
        return EventSynthesizer.Key(keyCode: UInt16(code), characters: plain, unmodified: plain, modifiers: modifiers)
    }

    private static func check(_ id: String, _ failures: [String], _ start: ContinuousClock.Instant,
                              title: String = "단축키") -> TestResult {
        .make(id, title, status: failures.isEmpty ? .pass : .fail, cause: .app,
              evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }
}
