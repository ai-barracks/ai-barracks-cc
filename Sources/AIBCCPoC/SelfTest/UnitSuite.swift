import Foundation

/// Pure checks that need no window: the liveness fold must match aib
/// (`aib sessions state`, CC v1.6.1 `live::fold` test matrix), and the
/// sidecar reader must apply the ack file.
@MainActor
struct UnitSuite {
    func run() -> [TestResult] {
        [foldMatrix(), readerAppliesAck(), attentionWindow(), commentsHidden(), launchCommand(), ackRoundTrip(),
         processTree(), maintenanceParsing(), socketChoice(), skillsAndCouncil()]
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

    private func launchCommand() -> TestResult {
        let start = ContinuousClock.now
        let claude = AgentLauncher.command(for: .claude, skipPermissions: true)
        let codex = AgentLauncher.command(for: .codex, skipPermissions: false)
        let ok = claude == "/bin/zsh -lc 'aib start claude --skip-permissions; exec /bin/zsh -l'"
            && codex == "/bin/zsh -lc 'aib start codex; exec /bin/zsh -l'"
            && AgentLauncher.command(for: .terminal, skipPermissions: true) == nil
        return .make("AG-01a", "에이전트 시작 명령 = aib start <client> (로그인 셸, 종료 후 셸 유지)",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["claude": claude ?? "nil", "codex": codex ?? "nil"], startedAt: start)
    }

    /// Byte-compatible with CC v1.6.1 write_ack; done → idle; bad ids refused.
    private func ackRoundTrip() -> TestResult {
        let start = ContinuousClock.now
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-ack-\(UUID().uuidString)")
        let live = root.appendingPathComponent("sessions/.live")
        try? FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Int(Date().timeIntervalSince1970)
        try? "{\"session_id\":\"s1\",\"run_id\":\"r1\",\"state\":\"done\",\"ts\":\(now),\"pid\":0}"
            .write(to: live.appendingPathComponent("s1.status"), atomically: true, encoding: .utf8)
        let before = LivenessReader.read(barrackPath: root.path, now: now).first?.state
        let wrote = LivenessAck.write(barrackPath: root.path, sessionID: "s1", runID: "r1", now: now)
        let after = LivenessReader.read(barrackPath: root.path, now: now).first?.state
        let refused = !LivenessAck.write(barrackPath: root.path, sessionID: "../x", runID: "r", now: now)
            && !LivenessAck.write(barrackPath: root.path, sessionID: "", runID: "r", now: now)
        let ok = before == .done && wrote && after == .idle && refused
        return .make("AT-01a", "done 확인(ack): CC 호환 .ack 기록 → idle, 잘못된 세션 id 거부",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["before": before?.rawValue ?? "nil", "after": after?.rawValue ?? "nil",
                                "refused_bad_ids": "\(refused)"], startedAt: start)
    }

    private func processTree() -> TestResult {
        let start = ContinuousClock.now
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["2"]
        try? child.run()
        defer { child.terminate() }
        let mine = ProcessInfo.processInfo.processIdentifier
        let descendant = ProcessTree.isDescendant(child.processIdentifier, of: mine)
        let unrelated = ProcessTree.isDescendant(mine, of: child.processIdentifier)
        let ok = descendant && !unrelated
        return .make("AT-01b", "pane 매칭용 프로세스 트리: 자식은 후손, 부모는 아님",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["child_is_descendant": "\(descendant)", "parent_is_descendant": "\(unrelated)"],
                     startedAt: start)
    }

    /// Real aib v1.6.0 output shapes (ANSI colors included).
    private func maintenanceParsing() -> TestResult {
        let start = ContinuousClock.now
        let clean = "\u{1B}[0;36m[INFO]\u{1B}[0m [dry-run] Would delete: sessions/claude-x.md\n\u{1B}[0;36m[INFO]\u{1B}[0m Would clean 1 empty session(s)"
        let lint = "  \u{1B}[0;33m[STALE]\u{1B}[0m wiki/topics/A.md: 2026-05-04\n\n\u{1B}[0;33m[WARN]\u{1B}[0m Wiki lint: 101 issue(s) found"
        let ok = "\u{1B}[0;32m[OK]\u{1B}[0m   Skills wiring is in sync"
        let quiet = MaintenanceScanner.parse(verify: "", clean: "", gc: "", lint: "", skills: ok,
                                             cliVersion: "aib v1.6.0", barrackVersion: "1.6.0", path: "/b")
        let busy = MaintenanceScanner.parse(verify: "claude-1 changed after seal", clean: clean, gc: "", lint: lint,
                                            skills: ok, cliVersion: "aib v1.6.0", barrackVersion: "1.5.0", path: "/b")
        let kinds = busy.map(\.kind)
        let counts = Dictionary(uniqueKeysWithValues: busy.map { ($0.kind, $0.count) })
        let pass = quiet.isEmpty && kinds == [.seal, .clean, .wikiLint, .versionDrift]
            && counts[.clean] == 1 && counts[.wikiLint] == 101
            && busy.first { $0.kind == .clean }?.command.contains("--dry-run && printf") == true
        return .make("MT-01a", "정비 항목 해석(aib 출력, 색 코드 포함)·적용 전 dry-run",
                     status: pass ? .pass : .fail, cause: .app,
                     evidence: ["quiet": "\(quiet.count)", "kinds": kinds.map(\.rawValue).joined(separator: ","),
                                "counts": counts.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ",")],
                     startedAt: start)
    }

    /// Daemon by default, but a self-test never lands on the user's socket.
    private func socketChoice() -> TestResult {
        let start = ContinuousClock.now
        let user = DaemonBackend.socketPath(for: ["app"]) ?? "nil"
        let test = DaemonBackend.socketPath(for: ["app", "--selftest"]) ?? "nil"
        let only = DaemonBackend.socketPath(for: ["app", "--selftest-only=input"]) ?? "nil"
        let explicit = DaemonBackend.socketPath(for: ["app", "--selftest", "--ptyd-socket=/tmp/x.sock"]) ?? "nil"
        let exec = DaemonBackend.socketPath(for: ["app", "--backend=exec"])
        let ok = user.hasSuffix("/ptyd-v1.sock") && test.hasSuffix("/ptyd-selftest.sock") && only == test
            && explicit == "/tmp/x.sock" && exec == nil
        return .make("DB-01a", "데몬 기본값·버전 소켓, self-test는 전용 소켓, --backend=exec는 데몬 없음",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["user": user, "selftest": test, "exec": exec ?? "nil"], startedAt: start)
    }

    private func skillsAndCouncil() -> TestResult {
        let start = ContinuousClock.now
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-sk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent("skills/council")
        let minutes = root.appendingPathComponent("resources/council")
        try? FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: minutes, withIntermediateDirectories: true)
        try? "---\nname: council\ndescription: \"Debate\"\n---\n# Body".write(
            to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try? "# m".write(to: minutes.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try? "# p".write(to: minutes.appendingPathComponent("a-prompt.md"), atomically: true, encoding: .utf8)
        let skills = BarrackDocuments.skills(in: root).map { $0.deletingLastPathComponent().lastPathComponent }
        let council = BarrackDocuments.councilMinutes(in: root).map(\.lastPathComponent)
        let header = BarrackDocuments.frontmatterAsHeader("---\nname: council\ndescription: \"Debate\"\n---\n# Body")
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9, minute: 5))!
        let command = CouncilCommand.make(topic: "REST 'vs' gRPC", rounds: 2, now: date)
        let ok = skills == ["council"] && council == ["a.md"] && header == "> **council** — Debate\n\n# Body"
            && command == "mkdir -p resources/council && aib council -r 2 -o resources/council/20261102-0905-council.md 'REST '\\''vs'\\'' gRPC'"
        return .make("SK-01a", "Skills·Council 문서 찾기, SKILL.md 머리글 표시, council 명령(-o, 따옴표)",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["skills": skills.joined(separator: ","), "council": council.joined(separator: ","),
                                "header": header, "command": command], startedAt: start)
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
