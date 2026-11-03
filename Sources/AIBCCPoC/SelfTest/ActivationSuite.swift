import Foundation

/// Scheduled activation (v1 activation.rs tests) on temp directories with
/// fake clocks and fake CLIs — never v1's real file, never a real model.
@MainActor
struct ActivationSuite {
    func run() -> [TestResult] {
        [schedule(), runner()]
    }

    private func check(_ id: String, _ title: String, _ failures: [String], _ start: ContinuousClock.Instant) -> TestResult {
        .make(id, title, status: failures.isEmpty ? .pass : .fail, cause: .app,
              evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    private func kst(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text + "+09:00")!
    }

    private func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Slots, file, claims

    private func schedule() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        if ActivationSchedule.slot(at: kst("2026-11-03T06:00:30")) != kst("2026-11-03T06:00:00")
            || ActivationSchedule.slot(at: kst("2026-11-03T06:01:00")) != nil || ActivationSchedule.slot(at: kst("2026-11-03T07:00:00")) != nil {
            failures.append("slot")
        }
        if ActivationSchedule.nextSlot(after: kst("2026-11-03T21:00:00")) != kst("2026-11-04T06:00:00")
            || ActivationSchedule.nextSlot(after: kst("2026-11-03T05:59:59")) != kst("2026-11-03T06:00:00") { failures.append("next slot") }
        if ActivationSchedule.format(kst("2026-11-03T06:00:00")) != "2026-11-03T06:00:00+09:00" { failures.append("format") }
        failures += fileRules() + claims() + lockAndCancel()
        return check("AC-01a", "예약 = v1(KST 06·11·16·21시, v1 파일 형식·크래시 후 interrupted, 디스크 선기록 후 실행, 슬롯당 한 번, 켠 직후 즉시 실행 없음, 끄면 취소, 잠금 배타)",
                     failures, start)
    }

    private func fileRules() -> [String] {
        var failures: [String] = []
        let v1 = #"{"version":1,"config":{"enabled":false,"claude":true,"codex":true},"last_claimed":{},"history":[]}"#
        guard case let .success(document) = ActivationSchedule.decode(Data(v1.utf8)) else { return ["v1 file"] }
        if ActivationSchedule.encode(document).flatMap({ try? ActivationSchedule.decode($0).get() }) != document { failures.append("round trip") }
        let keys = (try? JSONSerialization.jsonObject(with: ActivationSchedule.encode(document) ?? Data())) as? [String: Any]
        if Set(keys?.keys ?? [:].keys) != ["version", "config", "last_claimed", "history"] { failures.append("v1 keys") }
        let crashed = #"{"version":1,"config":{"enabled":true,"claude":true,"codex":false},"last_claimed":{"claude":1},"history":[{"provider":"claude","slot":"s","status":"running","detail":"d"}]}"#
        if (try? ActivationSchedule.decode(Data(crashed.utf8)).get())?.history.first?.status != "interrupted" { failures.append("interrupted") }
        for bad in [#"{"version":2}"#, #"{"version":1,"config":{"enabled":true,"claude":false,"codex":false}}"#,
                    #"{"version":1,"last_claimed":{"gemini":1}}"#, "not json"] {
            if case .success = ActivationSchedule.decode(Data(bad.utf8)) { failures.append("accepted \(bad.prefix(30))") }
        }
        return failures
    }

    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private final class Calls: @unchecked Sendable {
        var providers: [ActivationProvider] = []
        var statusOnDisk: [String] = []
    }

    private func claims() -> [String] {
        var failures: [String] = []
        let directory = temp("activation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(kst("2026-11-03T05:59:50"))
        let calls = Calls()
        let file = directory.appendingPathComponent("activation.json")
        let scheduler = ActivationScheduler(directory: directory, findBinary: { _ in URL(fileURLWithPath: "/usr/bin/true") },
                                            activate: { provider, _, _ in
                                                calls.providers.append(provider)
                                                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                                                calls.statusOnDisk.append(text.contains("\"running\"") ? "running" : "?")
                                                return .success(())
                                            }, clock: { clock.now })
        if case .success = scheduler.save(ActivationConfig(enabled: true, claude: false, codex: false)) { failures.append("empty selection saved") }
        clock.now = kst("2026-11-03T05:59:55")
        _ = scheduler.save(ActivationConfig(enabled: true, claude: true, codex: false))
        clock.now = kst("2026-11-03T06:00:10")
        scheduler.tick()
        clock.now = kst("2026-11-03T06:00:40")
        scheduler.tick()
        if calls.providers != [.claude] || calls.statusOnDisk != ["running"] { failures.append("claim once \(calls.providers) \(calls.statusOnDisk)") }
        let view = scheduler.view()
        if view.history.first?.status != "success" || view.nextSlot != kst("2026-11-03T11:00:00") { failures.append("history/next") }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int
        if permissions != 0o600 { failures.append("file mode \(String(permissions ?? 0, radix: 8))") }
        // Turning it on inside a slot waits for the next one.
        clock.now = kst("2026-11-03T11:00:20")
        _ = scheduler.save(ActivationConfig(enabled: true, claude: true, codex: true))
        clock.now = kst("2026-11-03T11:00:30")
        scheduler.tick()
        if calls.providers.count != 1 { failures.append("ran in the slot it was enabled in") }
        return failures
    }

    private final class Box: @unchecked Sendable { var scheduler: ActivationScheduler? }

    private func lockAndCancel() -> [String] {
        var failures: [String] = []
        let directory = temp("activation-lock")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(kst("2026-11-03T15:59:00"))
        let box = Box()
        let first = ActivationScheduler(directory: directory, findBinary: { _ in URL(fileURLWithPath: "/usr/bin/true") },
                                        activate: { _, _, cancelled in
                                            _ = box.scheduler?.save(ActivationConfig(enabled: false))
                                            return cancelled() ? .failure("Cancelled after settings changed") : .success(())
                                        }, clock: { clock.now })
        box.scheduler = first
        _ = first.save(ActivationConfig(enabled: true, claude: false, codex: true))
        let second = ActivationScheduler(directory: directory, clock: { clock.now })
        if second.view().available || second.view().error?.contains("다른 CommandCenter") != true { failures.append("lock not exclusive") }
        // The owner's setting is shown read-only.
        if second.view().config != ActivationConfig(enabled: true, claude: false, codex: true) || second.view().nextSlot != nil {
            failures.append("owner's setting not shown")
        }
        if case .success = second.save(ActivationConfig(enabled: true)) { failures.append("second instance saved") }
        _ = first.save(ActivationConfig(enabled: true, claude: true, codex: false))
        clock.now = kst("2026-11-03T16:00:05")
        first.tick()
        if first.view().history.first?.status != "failed" || first.view().config.enabled { failures.append("off did not cancel") }
        return failures
    }

    // MARK: - Runner against fake CLIs

    private func runner() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        if !ActivationRunner.isSubscriptionLogin(.claude, Data(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}"#.utf8))
            || ActivationRunner.isSubscriptionLogin(.claude, Data(#"{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty"}"#.utf8))
            || !ActivationRunner.isSubscriptionLogin(.codex, Data("Logged in using ChatGPT\n".utf8))
            || ActivationRunner.isSubscriptionLogin(.codex, Data("Logged in using an API key".utf8)) { failures.append("auth rules") }
        let completed = [#"{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}"#, #"{"type":"turn.completed"}"#]
        if !ActivationRunner.isValidResponse(.codex, Data(completed.joined(separator: "\n").utf8))
            || ActivationRunner.isValidResponse(.codex, Data(([#"{"type":"item.started","item":{"type":"command_execution"}}"#] + completed).joined(separator: "\n").utf8))
            || ActivationRunner.isValidResponse(.claude, Data(#"{"type":"result","subtype":"success","is_error":false,"result":"OK, done"}"#.utf8)) {
            failures.append("response rules")
        }
        failures += fakeRuns()
        return check("AC-01b", "활성화 실행 = v1(구독 로그인만·정확한 OK만·도구 사용 거부·임시 cwd·v1 인자, 시간 초과 시 프로세스 그룹 전체 종료)",
                     failures, start)
    }

    private func fakeRuns() -> [String] {
        var failures: [String] = []
        let directory = temp("fake-cli")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("log")
        let fake = { (name: String, body: String) -> URL in
            let url = directory.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data(("#!/bin/sh\n" + body).utf8), attributes: [.posixPermissions: 0o700])
            return url
        }
        let claude = fake("claude", """
        if [ "$1" = auth ]; then echo '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'; exit 0; fi
        printf '%s\\n' "$PWD" "$@" > '\(log.path)'
        echo '{"type":"result","subtype":"success","is_error":false,"result":"OK"}'
        """)
        let ok = ActivationRunner.activate(.claude, binary: claude, cancelled: { false })
        let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        if case .failure = ok { failures.append("claude fake failed \(ok)") }
        if lines.first?.contains("aibcc-activation-") != true || Array(lines.dropFirst().prefix(ActivationRunner.requestArguments(.claude).count))
            != ActivationRunner.requestArguments(.claude) { failures.append("claude argv/cwd") }
        try? FileManager.default.removeItem(at: log)
        let apiKey = fake("claude-api", """
        if [ "$1" = auth ]; then echo '{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty"}'; exit 0; fi
        touch '\(log.path)'; echo '{"type":"result","subtype":"success","is_error":false,"result":"OK"}'
        """)
        if case .success = ActivationRunner.activate(.claude, binary: apiKey, cancelled: { false }) { failures.append("api key accepted") }
        if FileManager.default.fileExists(atPath: log.path) { failures.append("request sent without subscription login") }
        let codexTool = fake("codex", """
        if [ "$1" = login ]; then echo 'Logged in using ChatGPT' >&2; exit 0; fi
        echo '{"type":"item.started","item":{"type":"command_execution"}}'
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}'
        echo '{"type":"turn.completed"}'
        """)
        if case .success = ActivationRunner.activate(.codex, binary: codexTool, cancelled: { false }) { failures.append("tool use accepted") }
        let pidFile = directory.appendingPathComponent("grandchild")
        let hanging = fake("hang", """
        if [ "$1" = auth ]; then echo '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'; exit 0; fi
        sleep 300 & echo $! > '\(pidFile.path)'
        sleep 300
        """)
        let began = Date()
        let timedOut = ActivationRunner.activate(.claude, binary: hanging, requestTimeout: 1, cancelled: { false })
        let grandchild = Int32(((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        usleep(200_000)
        let timedOutRight: Bool = { if case .failure("CLI timed out; not retried") = timedOut { return true }; return false }()
        if !timedOutRight || Date().timeIntervalSince(began) > 5 { failures.append("timeout \(timedOut)") }
        if grandchild <= 0 || kill(grandchild, 0) == 0 { failures.append("grandchild survived") }
        return failures
    }
}
