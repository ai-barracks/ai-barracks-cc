import Foundation
import GhosttyTerminal

/// Codex r6 (2026-11-05) findings on the r4/r5 fixes, each as a regression.
@MainActor
struct ReviewR6Suite {
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.withLock { items.append(item) } }
        var all: [String] { lock.withLock { items } }
    }

    func run() -> [TestResult] {
        [backlogReentry(), documents()]
    }

    /// R6-01c: an aib write typed into a pane (Sync All, ⌘K aib sync) ran
    /// beside the app's own queued writes; both now hold one file lock.
    func writeLock() async -> TestResult {
        let start = ContinuousClock.now
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-r6-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let started = directory.appendingPathComponent("started").path
        let ended = directory.appendingPathComponent("ended").path
        let paneApply = AibWriteLock.wrap("touch '\(started)'; sleep 1; touch '\(ended)'")
        let pane = Task { await ProcessOutput.runWithStatus(URL(fileURLWithPath: "/bin/sh"), ["-c", paneApply], in: directory.path) }
        var holding = false
        for _ in 0 ..< 50 where !holding {
            try? await Task.sleep(for: .milliseconds(50))
            holding = FileManager.default.fileExists(atPath: started)
        }
        let waited = await AibWriteQueue.run { FileManager.default.fileExists(atPath: ended) }
        let status = await pane.value.status
        let ok = holding && waited && status == 0
        return .make("R6-01c", "pane에서 적용하는 aib 쓰기와 앱 큐의 aib 쓰기가 같은 잠금으로 직렬화",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["pane_holding": "\(holding)", "queue_waited_for_pane": "\(waited)", "pane_status": "\(status)"],
                     startedAt: start)
    }

    /// R6-01b: shapes the r5 form-editor guards still let through.
    private func documents() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        // A quoted or flow value that goes on at the same indentation.
        for raw in ["name: a\nmodels:\n  primary: \"first\n  second\"\n",
                    "name: a\nmodels:\n  primary: 'first\n  second'\n",
                    "name: a\nmodels:\n  primary: [one,\n  two]\n"] {
            var next = AgentYamlDocument.parse(raw)
            next.primaryModel = "new"
            if AgentYamlDocument.patch(raw, to: next) != .failure(.init(field: .primaryModel, reason: .multilineValue)) {
                failures.append("yaml \(raw.dropFirst(18).prefix(12))")
            }
        }
        let closed = "name: a\nmodels:\n  primary: \"say \\\"hi\\\"\"\n  fallback: []\n"
        var closedNext = AgentYamlDocument.parse(closed)
        closedNext.primaryModel = "new"
        if case .failure = AgentYamlDocument.patch(closed, to: closedNext) { failures.append("closed quote refused") }
        // An ordered sub-list or a continued item body after the run.
        for tail in ["  1. child\n", "continued body\n", "\n  second paragraph\n"] {
            let raw = "## Must Always\n- a\n- b\n" + tail + "\n## Must Never\n\n## Learned\n"
            var rules = RulesDocument.parse(raw)
            rules.mustAlways = ["a"]
            if case let .failure(failure) = RulesDocument.patch(raw, to: rules), failure.reason == .nestedBullets {} else {
                failures.append("hanging \(tail.prefix(8))")
            }
        }
        let plainRules = "## Must Always\n- a\n- b\n\n## Must Never\n\n## Learned\n"
        var plainNext = RulesDocument.parse(plainRules)
        plainNext.mustAlways = ["a"]
        if case .failure = RulesDocument.patch(plainRules, to: plainNext) { failures.append("plain list refused") }
        // The form and the tokenizer agree on backslashes before a pipe.
        let cells: [(String, Bool)] = [("A \\| B", true), ("A \\\\| B", false), ("A \\\\\\| B", true), ("A | B", false), ("plain", true)]
        for (text, expected) in cells where GrowthDocument.isCellText(text) != expected { failures.append("cell \(text)") }
        let table = "| 세션 중 이벤트 | 기록 위치 | 예시 |\n|---|---|---|\n| E | L | X |\n"
        var growth = GrowthDocument.parse(table)
        growth.decisionTable[0].event = "A \\\\| B"
        if case .failure(.init(field: .decisionTable, reason: .malformedRow)) = GrowthDocument.patch(table, to: growth) {} else {
            failures.append("bad row written")
        }
        // A raw edit of `name` survives the switch to the form: still checked.
        let renamed = "---\nname: bar\ndescription: Does the thing for the test suite\n---\nBody\n"
        let viaForm = try? SkillEditBuffer.toRaw(base: renamed, fields: SkillDocument.fields(renamed), body: "Body\n").get()
        if viaForm.map({ SkillDocument.saveProblem($0, slug: "foo") == nil }) != false { failures.append("skill name bypass") }
        if SkillDocument.saveProblem("---\nname: foo\ndescription: ok\n---\n", slug: "foo") != nil { failures.append("valid skill refused") }
        return .make("R6-01b", "YAML 따옴표·flow 여러 줄 값, 목록 뒤 이어지는 내용, 셀의 \\\\|, 폼 경유 skill name — 거부",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// R6-01a: libghostty patch 4 delivered backlog changes holding a lock,
    /// so a handler that replaced itself (or another thread waiting on that
    /// lock while holding the session's) deadlocked.
    private func backlogReentry() -> TestResult {
        let start = ContinuousClock.now
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let seen = Seen()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            session.setOutputBacklogHandler(highWater: 1000, lowWater: 100) { backlogged in
                seen.add("first:\(backlogged):\(session.pendingOutputByteCount)")
                guard backlogged else { return }
                session.setOutputBacklogHandler(highWater: 1000, lowWater: 100) { again in seen.add("second:\(again)") }
            }
            // No surface: the bytes stay queued and cross the high-water mark.
            session.receive(Data(repeating: 0x61, count: 2000))
            done.signal()
        }
        let finished = done.wait(timeout: .now() + 5) == .success
        let ok = finished && seen.all == ["first:true:2000", "second:true"]
        return .make("R6-01a", "backlog 통지 handler가 세션을 다시 불러도 교착 없음, 순서 유지",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["finished": "\(finished)", "seen": seen.all.joined(separator: ",")], startedAt: start)
    }
}
