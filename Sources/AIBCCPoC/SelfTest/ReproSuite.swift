import AppKit

/// Known issue #10: a key pressed in the same turn as a pane swap was lost
/// 2/5 times (IN-09, 2026-11-01). Explicit suite (`--selftest-only=repro10`):
/// swap in a fresh recorder pane, focus it and press at once, many times,
/// for a control key and a plain letter, and record where lost keys went.
@MainActor
struct ReproSuite {
    let harness: SelfTestHarness
    private static let trials = 15

    struct Trial {
        let delivered: Bool
        let focused: Bool
        let responder: String
        let trace: String
    }

    func run() async -> [TestResult] {
        guard let window = harness.window, let ctrlC = EventSynthesizer.control("c"),
              let letter = EventSynthesizer.key("x")
        else { return [] }
        return [
            await measure("RP-10a", "pane 교체 직후 Ctrl+C", key: ctrlC, expected: [0x03], window),
            await measure("RP-10b", "pane 교체 직후 일반 문자", key: letter, expected: [0x78], window),
            await originalCondition(ctrlC, window),
            await originalCondition(ctrlC, window, afterPredecessors: true),
        ]
    }

    /// What ran right before IN-09: a Korean input-source round trip and a
    /// bracketed-paste pane that received a paste, then the swap.
    private func predecessors(_ window: NSWindow) async {
        guard let paster = harness.makeRecorderPane(name: "repro-paste", environment: ["AIBCC_BRACKETED_PASTE": "1"]),
              let letter = EventSynthesizer.key("r")
        else { return }
        await harness.install([paster.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { paster.log.isReady }
        harness.focus(paster.pane)
        _ = await InputSourceGuard.with(InputSourceGuard.korean2Set) { EventSynthesizer.press(letter, in: window) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("repro paste\nline", forType: .string)
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        _ = await harness.settledBytes(paster.log, since: 0)
    }

    /// The exact IN-09 condition that lost the key: a shell fixture that is
    /// ready within milliseconds, pressed without draining the swap.
    private func originalCondition(
        _ key: EventSynthesizer.Key, _ window: NSWindow, afterPredecessors: Bool = false
    ) async -> TestResult {
        let start = ContinuousClock.now
        var lost: [String] = []
        for index in 0..<Self.trials {
            if afterPredecessors { await predecessors(window) }
            let temp = FileManager.default.temporaryDirectory
            let ready = temp.appendingPathComponent("aibcc-repro-ready-\(UUID().uuidString)")
            let hit = temp.appendingPathComponent("aibcc-repro-hit-\(UUID().uuidString)")
            guard let pane = harness.makeScriptPane(
                name: "repro-sigint-\(index)", script: "sigint_probe.sh", readyFile: ready,
                environment: [AppConstants.Environment.signalFile: hit.path]
            ) else { continue }
            await harness.install([pane], layout: .single)
            _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) {
                FileManager.default.fileExists(atPath: ready.path)
            }
            harness.focus(pane)
            let focused = harness.isFirstResponder(pane.probeView)
            let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            EventSynthesizer.press(key, in: window)
            let delivered = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
                FileManager.default.fileExists(atPath: hit.path)
            }
            if !delivered {
                let trace = pane.probeView?.callLog.suffix(6)
                    .map { "\($0.kind.rawValue):\($0.text ?? "")" }.joined(separator: " ") ?? ""
                lost = lost + ["#\(index) focused=\(focused) responder=\(responder) trace=[\(trace)]"]
            }
        }
        let id = afterPredecessors ? "RP-10d" : "RP-10c"
        let condition = afterPredecessors ? "IN-09 직전 순서(한글 입력 소스 왕복·bracketed paste pane) 재현 후" : "IN-09 원래 조건"
        return .make(id, "\(condition)(즉시 준비되는 셸, drain 없음) — \(Self.trials)회 중 유실 \(lost.count)",
                     status: lost.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["lost": "\(lost.count)/\(Self.trials)", "lost_detail": lost.joined(separator: " | ")],
                     startedAt: start)
    }

    private func measure(_ id: String, _ title: String, key: EventSynthesizer.Key, expected: [UInt8],
                         _ window: NSWindow) async -> TestResult {
        let start = ContinuousClock.now
        var trials: [Trial] = []
        for index in 0..<Self.trials {
            guard let recorder = harness.makeRecorderPane(name: "repro-\(id)-\(index)") else { continue }
            await harness.install([recorder.pane], layout: .single)
            _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorder.log.isReady }
            let mark = recorder.log.mark()
            harness.focus(recorder.pane)
            let focused = harness.isFirstResponder(recorder.pane.probeView)
            let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            EventSynthesizer.press(key, in: window)
            let bytes = await harness.settledBytes(recorder.log, since: mark)
            let trace = recorder.pane.probeView?.callLog.suffix(4)
                .map { "\($0.kind.rawValue):\($0.text ?? "")" }.joined(separator: " ") ?? ""
            trials = trials + [Trial(delivered: bytes == expected, focused: focused, responder: responder, trace: trace)]
        }
        let lost = trials.enumerated().filter { !$0.element.delivered }
        return .make(id, "\(title) — \(Self.trials)회 중 유실 \(lost.count)",
                     status: lost.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["lost": "\(lost.count)/\(trials.count)",
                                "lost_detail": lost.map { "#\($0.offset) focused=\($0.element.focused) "
                                    + "responder=\($0.element.responder) trace=[\($0.element.trace)]" }
                                    .joined(separator: " | ")],
                     startedAt: start)
    }
}
