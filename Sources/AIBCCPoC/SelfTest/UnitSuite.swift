import Foundation

/// Pure checks that need no window: the liveness fold must match aib
/// (`aib sessions state`, CC v1.6.1 `live::fold` test matrix), and the
/// sidecar reader must apply the ack file.
@MainActor
struct UnitSuite {
    func run() -> [TestResult] {
        [foldMatrix(), readerAppliesAck(), attentionWindow(), commentsHidden()]
    }

    private func foldMatrix() -> TestResult {
        let start = ContinuousClock.now
        let now = 1_000_000, stale = 180
        let ack = Liveness.Ack(runID: "r", timestamp: now)
        let cases: [(String, Int, Liveness.Ack?, Liveness.PidState, Liveness)] = [
            ("blocked", now - 99_999, nil, .alive, .blocked),
            ("blocked", now, nil, .unknown, .blocked),
            ("blocked", now, nil, .dead, .crashed),
            ("working", now, nil, .alive, .working),
            ("working", now - stale, nil, .alive, .working),
            ("working", now - stale - 1, nil, .alive, .workingStale),
            ("working", now - stale - 1, nil, .unknown, .workingStale),
            ("working", now, nil, .dead, .interrupted),
            ("done", now, nil, .alive, .done),
            ("done", now, nil, .dead, .done),
            ("done", now, ack, .alive, .idle),
            ("done", now, Liveness.Ack(runID: "other", timestamp: now), .alive, .done),
            ("done", now + 5, ack, .alive, .done),
            ("mystery", now, nil, .alive, .none),
        ]
        let failures = cases.enumerated().compactMap { index, item -> String? in
            let got = Liveness.fold(state: item.0, statusTimestamp: item.1, runID: "r", ack: item.2,
                                    now: now, pid: item.3, staleAfter: stale)
            return got == item.4 ? nil : "#\(index) \(item.0) → \(got.rawValue), expected \(item.4.rawValue)"
        }
        return .make("LV-01a", "liveness 접기 = aib 규칙(\(cases.count)개 조합)",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// Incident 2026-11-01: finishes 1 h–152 days old rang on five barracks.
    private func attentionWindow() -> TestResult {
        let start = ContinuousClock.now
        let window = AppConstants.Liveness.attentionWindow
        let session = { (state: Liveness, age: Int) in LiveSession(id: "s", state: state, ageSeconds: age, pid: 1, cwd: nil) }
        let cases: [(LiveSession, Bool)] = [
            (session(.done, 60), true), (session(.done, window + 1), false),
            (session(.crashed, 60), true), (session(.crashed, window + 1), false),
            (session(.blocked, window * 10), true), (session(.working, 0), false), (session(.idle, 0), false),
        ]
        let failures = cases.enumerated().filter { $0.element.0.needsAttention != $0.element.1 }.map { "#\($0.offset)" }
        return .make("LV-01c", "attention ring: blocked는 항상, done·crashed는 12시간 안만",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: ",")], startedAt: start)
    }

    /// aib metadata comments showed as literal text in document views.
    private func commentsHidden() -> TestResult {
        let start = ContinuousClock.now
        let source = "<!-- AIB:OWNERSHIP — [AUTO-GROW] x -->\n# Rules\nkeep <!-- inline --> this\n<!-- multi\nline -->\n```html\n<!-- in code -->\n```\nend"
        let expected = "# Rules\nkeep  this\n```html\n<!-- in code -->\n```\nend"
        let got = MarkdownSource.forDisplay(source)
        return .make("MD-08a", "aib 메타데이터 주석은 표시에서 빠지고 코드 블록 안 주석은 유지",
                     status: got == expected ? .pass : .fail, cause: .app,
                     evidence: ["got": got.replacingOccurrences(of: "\n", with: "⏎")], startedAt: start)
    }

    private func readerAppliesAck() -> TestResult {
        let start = ContinuousClock.now
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-lv-\(UUID().uuidString)")
        let live = root.appendingPathComponent("sessions/.live")
        try? FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Int(Date().timeIntervalSince1970)
        let status = { (id: String, state: String) in
            "{\"session_id\":\"\(id)\",\"run_id\":\"run-\(id)\",\"state\":\"\(state)\",\"ts\":\(now),\"pid\":0}"
        }
        try? status("a", "done").write(to: live.appendingPathComponent("a.status"), atomically: true, encoding: .utf8)
        try? status("b", "done").write(to: live.appendingPathComponent("b.status"), atomically: true, encoding: .utf8)
        try? "{\"acked_run_id\":\"run-b\",\"ack_ts\":\(now)}".write(
            to: live.appendingPathComponent("b.ack"), atomically: true, encoding: .utf8)
        let states = Dictionary(uniqueKeysWithValues: LivenessReader.read(barrackPath: root.path, now: now).map { ($0.id, $0.state) })
        let ok = states == ["a": .done, "b": .idle]
        return .make("LV-01b", "sidecar 읽기: ack가 맞으면 done → idle",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["states": states.map { "\($0.key)=\($0.value.rawValue)" }.sorted().joined(separator: ",")],
                     startedAt: start)
    }
}
