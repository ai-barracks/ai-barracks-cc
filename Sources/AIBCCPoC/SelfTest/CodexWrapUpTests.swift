import Foundation

/// "정리하고 닫기" for a Codex without aib's hooks (2026-11-25: the request
/// was typed and done, and the terminal stayed — aib wrote no turn end, and
/// the request had promised the app would close it). The turn end comes
/// from Codex's own transcript, in the shape Codex 0.160/0.167 wrote it.
@MainActor
struct CodexWrapUpTests {
    let harness: SelfTestHarness

    func run() async -> [TestResult] { [await closesCodex()] }

    // MARK: - Transcript lines as Codex writes them

    static let base = Date(timeIntervalSince1970: 1_800_000_000)
    static let request = AppConstants.WrapUp.requestBody

    static func line(_ type: String, _ payload: [String: Any], _ seconds: TimeInterval) -> String {
        let time = base.addingTimeInterval(seconds).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let object: [String: Any] = ["timestamp": time, "type": type, "payload": payload]
        return (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func started(_ id: String, _ at: TimeInterval) -> String {
        line("event_msg", ["type": "task_started", "turn_id": id], at)
    }

    static func user(_ text: String, _ at: TimeInterval) -> String {
        line("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]], at)
    }

    static func complete(_ id: String, _ answer: String?, _ at: TimeInterval, error: Bool = false) -> String {
        let payload: [String: Any] = ["type": "task_complete", "turn_id": id, "last_agent_message": answer ?? NSNull()]
        return line("event_msg", error ? payload.merging(["error": ["message": "model_not_found"]]) { $1 } : payload, at)
    }

    static func aborted(_ id: String, _ at: TimeInterval) -> String {
        line("event_msg", ["type": "turn_aborted", "turn_id": id, "reason": "interrupted"], at)
    }

    static func context(_ id: String, _ cwd: String, _ at: TimeInterval) -> String {
        line("turn_context", ["turn_id": id, "cwd": cwd, "model": "m"], at)
    }

    private static func parse(_ lines: [String]) -> [Substring] { lines.map { Substring($0) } }

    // MARK: - WU-02a

    /// WU-02a: which turn carries the request and how it ended; whether
    /// Codex is mid-reply; reading only what came after the request.
    static func rules() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let earlier = [started("a", -60), user(request, -59), complete("a", "정리했습니다", -30)]
        let cases: [(String, [String], CodexTranscript.Turn)] = [
            ("empty", [], .notYet),
            ("only an earlier wrap-up", earlier, .notYet),
            ("another message", [started("b", 1), user("다른 질문", 1), complete("b", "답", 5)], .notYet),
            ("running", [started("b", 1), user("# AGENTS.md instructions", 1), user(request, 1)], .running),
            ("finished", [started("b", 1), user(request, 1), complete("b", "정리했습니다", 40)], .finished(at: base.addingTimeInterval(40))),
            ("model error", [started("b", 1), user(request, 1), complete("b", nil, 2, error: true)], .failed),
            ("no answer", [started("b", 1), user(request, 1), complete("b", "", 2)], .failed),
            ("stopped by the user", [started("b", 1), user(request, 1), aborted("b", 9)], .failed),
            ("another turn ended", [started("b", 1), user(request, 1), complete("c", "다른 답", 9)], .running),
            ("request before its start", [user(request, 1), started("b", 1), complete("b", "정리했습니다", 9)], .finished(at: base.addingTimeInterval(9))),
            ("older Codex", [started("b", 1), line("event_msg", ["type": "user_message", "message": request], 1), complete("b", "정리했습니다", 9)],
             .finished(at: base.addingTimeInterval(9))),
        ]
        for (name, lines, expected) in cases {
            let got = CodexTranscript.turn(of: request, since: base, lines: parse(earlier + lines))
            if got != expected { failures.append("\(name): \(got) ≠ \(expected)") }
        }
        failures += folders() + midTurn() + decisions() + files()
        return .make("WU-02a", "Codex 정리하고 닫기 판정: 요청이 든 턴이 답을 내고 끝난 지 3초 뒤 닫음(오류·중단은 닫지 않음, 2분 안에 요청이 안 보이면 포기), 작업 중인 Codex에는 입력 안 함, 요청 뒤에 쓰인 기록만 읽음, 터미널 밖 기록은 이 폴더의 턴만",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// A transcript the terminal does not hold: only a turn in its folder.
    private static func folders() -> [String] {
        var failures: [String] = []
        let here = "/barracks/a"
        let wrap = { (id: String, folder: String?, end: TimeInterval) in
            [started(id, end - 9)] + (folder.map { [context(id, $0, end - 9)] } ?? []) + [user(request, end - 8), complete(id, "정리했습니다", end)]
        }
        let folders: [(String, [String], CodexTranscript.Turn)] = [
            ("another barrack's wrap-up", wrap("b", "/barracks/b", 20), .notYet),
            ("this barrack's", wrap("b", here, 20), .finished(at: base.addingTimeInterval(20))),
            ("folder unknown", wrap("b", nil, 20), .notYet),
            ("another's, then this one's", wrap("b", "/barracks/b", 20) + wrap("c", here, 40), .finished(at: base.addingTimeInterval(40))),
            ("folder told after the request",
             [started("b", 1), user(request, 1), context("b", here, 1), complete("b", "정리했습니다", 9)], .finished(at: base.addingTimeInterval(9))),
            ("still running elsewhere", [started("b", 1), context("b", "/barracks/b", 1), user(request, 1)], .notYet),
        ]
        for (name, lines, expected) in folders {
            let got = CodexTranscript.turn(of: request, since: base, lines: parse(lines), cwd: here)
            if got != expected { failures.append("folder \(name): \(got) ≠ \(expected)") }
        }
        if !CodexTranscript.samePath("/tmp", "/private/tmp") || CodexTranscript.samePath("/tmp", nil) {
            failures.append("folders compared without resolving links")
        }
        return failures
    }

    private static func midTurn() -> [String] {
        var failures: [String] = []
        let mid: [(String, [String], Bool, Bool)] = [
            ("new transcript", [], false, false), ("long turn past the tail", [], true, true),
            ("turn running", [started("a", 0), user("일", 0)], false, true),
            ("turn ended", [started("a", 0), complete("a", "답", 5), line("event_msg", ["type": "token_count"], 6)], false, false),
            ("turn stopped", [started("a", 0), aborted("a", 5)], false, false),
        ]
        for (name, lines, truncated, expected) in mid where CodexTranscript.isMidTurn(lines: parse(lines), truncated: truncated) != expected {
            failures.append("mid-turn \(name) ≠ \(expected)")
        }
        return failures
    }

    private static func decisions() -> [String] {
        let watch = WrapUp.CodexWatch(offsets: [:], owned: [], cwd: nil, home: "/nonexistent")
        let wrapUp = WrapUp(paneID: UUID(), barrackID: "b", requestedAt: base, tracker: .codexTranscript(watch))
        let settle = TimeInterval(AppConstants.WrapUp.settleSeconds)
        let cases: [(String, CodexTranscript.Turn, Bool, TimeInterval, WrapUpRule.Decision)] = [
            ("just finished", .finished(at: base.addingTimeInterval(40)), false, 41, .wait),
            ("finished and settled", .finished(at: base.addingTimeInterval(40)), false, 40 + settle, .close),
            ("failed", .failed, false, 50, .failed),
            ("not in the transcript yet", .notYet, false, 60, .wait),
            ("never in the transcript", .notYet, false, AppConstants.WrapUp.codexNotSeenTimeout + 1, .notFound),
            ("long wrap-up", .running, false, 600, .wait),
            ("never finished", .running, false, AppConstants.WrapUp.timeout + 1, .expire),
            ("terminal gone", .finished(at: base), true, 60, .forget),
        ]
        return cases.compactMap { name, turn, gone, after, expected in
            let got = WrapUpRule.decide(wrapUp, codex: turn, paneGone: gone, now: base.addingTimeInterval(after))
            return got == expected ? nil : "\(name): \(got) ≠ \(expected)"
        }
    }

    /// Offsets: a wrap-up already in the file before the request is not this
    /// one; a long turn whose start is past the tail still counts as running.
    private static func files() -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-wu2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-test.jsonl")
        var failures: [String] = []
        let write = { (lines: [String]) in
            let data = Data(lines.map { $0 + "\n" }.joined().utf8)
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: file)
            }
        }
        let mine = { (offsets: [String: UInt64]) in
            CodexTranscript.turn(of: request, since: base, owned: [file], others: [], offsets: offsets, cwd: nil)
        }
        write([started("a", 1), user(request, 1), complete("a", "정리했습니다", 9)])
        let offsets = CodexTranscript.sizes([file])
        if CodexTranscript.isMidTurn(at: file) { failures.append("ended turn read as mid-turn") }
        write([started("b", 20), user(request, 20)])
        if mine(offsets) != .running { failures.append("the wrap-up before the request was taken for this one") }
        if mine([:]) != .finished(at: base.addingTimeInterval(9)) { failures.append("reading from the start did not find the earlier wrap-up") }
        if !CodexTranscript.isMidTurn(at: file) { failures.append("running turn not mid-turn") }
        let padding = String(repeating: "x", count: Int(AppConstants.WrapUp.transcriptTailBytes))
        write([line("response_item", ["type": "function_call_output", "output": padding], 30)])
        if !CodexTranscript.isMidTurn(at: file) { failures.append("turn longer than the tail not mid-turn") }
        write([complete("b", "정리했습니다", 60)])
        if mine(offsets) != .finished(at: base.addingTimeInterval(60)) { failures.append("finish after a long output not found") }
        if CodexTranscript.isMidTurn(at: file) { failures.append("finished turn still mid-turn") }
        // Not held by the terminal: counted only with the terminal's folder.
        let elsewhere = { (cwd: String?) in
            CodexTranscript.turn(of: request, since: base, owned: [], others: [file], offsets: offsets, cwd: cwd)
        }
        if elsewhere("/barracks/a") != .notYet || elsewhere(nil) != .notYet { failures.append("a turn of no known folder counted") }
        return failures + homes(directory)
    }

    /// Which transcripts are watched when the terminal holds none: those
    /// written in the last week, and those started since the request.
    private static func homes(_ directory: URL) -> [String] {
        let home = directory.appendingPathComponent("codex-home")
        let day = home.appendingPathComponent("sessions/2026/11/25")
        let old = home.appendingPathComponent("sessions/2026/10/01")
        for folder in [day, old] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let recent = day.appendingPathComponent("rollout-2026-11-25T07-00-00-a.jsonl")
        let stale = old.appendingPathComponent("rollout-2026-10-01T07-00-00-b.jsonl")
        for file in [recent, stale, day.appendingPathComponent("notes.txt")] { FileManager.default.createFile(atPath: file.path, contents: Data("{}\n".utf8)) }
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 12)) ?? base
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: recent.path)
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 86_400)], ofItemAtPath: stale.path)
        var failures: [String] = []
        let watched = CodexTranscript.recentTranscripts(in: home, now: now).map(\.lastPathComponent)
        if watched != [recent.lastPathComponent] { failures.append("recent: \(watched)") }
        let started = CodexTranscript.transcripts(startedAround: now, in: home, now: now).map(\.lastPathComponent)
        if started != [recent.lastPathComponent] { failures.append("started today: \(started)") }
        return failures
    }

    // MARK: - WU-02b

    /// WU-02b: the transcript a terminal's process holds open is found from
    /// the terminal's process; other open files are not.
    static func discovery() async -> TestResult {
        let start = ContinuousClock.now
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-wu2d-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = directory.appendingPathComponent("sessions/2026/11/25")
        try? FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let transcript = day.appendingPathComponent("rollout-2026-11-25T07-49-32-test.jsonl")
        let log = directory.appendingPathComponent("rollout-not-in-sessions.jsonl")
        let holders = [transcript, log].compactMap(Self.hold)
        defer { holders.forEach { $0.process.terminate(); try? $0.input.fileHandleForWriting.close() } }
        var failures: [String] = holders.count == 2 ? [] : ["could not start holders"]
        _ = await waitFor { CodexTranscript.openTranscripts(under: getpid()).count >= 1 }
        let found = CodexTranscript.openTranscripts(under: getpid()).map(\.lastPathComponent)
        if found != [transcript.lastPathComponent] { failures.append("found \(found)") }
        let others = holders.first.map { CodexTranscript.openTranscripts(under: $0.process.processIdentifier) } ?? []
        if !others.isEmpty { failures.append("a process's own transcript counted as its child's") }
        if !CodexTranscript.openTranscripts(under: nil).isEmpty || !CodexTranscript.openTranscripts(under: 0).isEmpty {
            failures.append("no process still found transcripts")
        }
        return .make("WU-02b", "Codex 정리하고 닫기: 터미널 아래 프로세스가 열어 둔 Codex 기록(sessions/…/rollout-*.jsonl)만 찾음",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | "), "found": found.joined(separator: ",")], startedAt: start)
    }

    /// A child that keeps `file` open for writing, as Codex does.
    private static func hold(_ file: URL) -> (process: Process, input: Pipe)? {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: file) else { return nil }
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = input
        process.standardOutput = output
        guard (try? process.run()) != nil else { return nil }
        try? output.close()
        return (process, input)
    }

    private static func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return condition()
    }

    // MARK: - WU-02c

    /// WU-02c: in terminals — a busy Codex gets nothing typed; an idle one
    /// gets the request with the close promise and closes once its
    /// transcript shows the turn answered and settled; a failed turn leaves
    /// it open; an agent nothing reports on gets the request without it.
    private func closesCodex() async -> TestResult {
        let start = ContinuousClock.now
        guard let codex = harness.makeRecorderPane(name: "wu2-codex", agent: .codex),
              let failing = harness.makeRecorderPane(name: "wu2-fail", agent: .codex),
              let bare = harness.makeRecorderPane(name: "wu2-bare", agent: .claude),
              let served = harness.makeRecorderPane(name: "wu2-served", agent: .codex)
        else { return Self.fail("WU-02c", "setup", start) }
        let all = [codex, failing, bare, served]
        await harness.install(all.map(\.pane), layout: .quad)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { all.allSatisfy(\.log.isReady) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-wu2c-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = Fixture(directory)
        var failures = await closesWhenAnswered(codex, files)
        failures += failedTurnStaysOpen(failing.pane, home: files.home)
        failures += await closesFromServerTranscript(served.pane, server: files.server, home: files.home)
        failures += await typesOnly(bare)
        return .make("WU-02c", "Codex(aib hook 없음) 정리하고 닫기: 작업 중이면 입력 안 함, 요청 뒤 Codex 기록에 답이 남고 3초 뒤 닫음(턴 중엔 유지, 오류면 유지, 터미널 밖 기록은 이 폴더의 턴으로), 턴 끝을 알 수 없는 에이전트엔 '앱이 닫습니다' 없이 입력만",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// Transcripts for WU-02c: one mid-turn, one idle (both the terminal's),
    /// one in a Codex home that no process of the terminal holds.
    @MainActor
    private struct Fixture {
        let home: URL
        let busy: URL
        let idle: URL
        let server: URL

        init(_ directory: URL) {
            home = directory.appendingPathComponent("codex-home")
            let day = home.appendingPathComponent("sessions/2026/11/25")
            try? FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
            busy = directory.appendingPathComponent("rollout-busy.jsonl")
            idle = directory.appendingPathComponent("rollout-idle.jsonl")
            server = day.appendingPathComponent("rollout-2026-11-25T07-00-00-server.jsonl")
            try? Data((CodexWrapUpTests.started("a", 0) + "\n").utf8).write(to: busy)
            let ended = [CodexWrapUpTests.started("a", 0), CodexWrapUpTests.complete("a", "답", 5)].map { $0 + "\n" }.joined()
            for file in [idle, server] { try? Data(ended.utf8).write(to: file) }
        }
    }

    /// Busy: nothing typed. Idle: the request with the close, watched from
    /// the transcripts' sizes, closed once Codex's own lines (read for real)
    /// show the turn answered and settled.
    private func closesWhenAnswered(_ codex: SelfTestHarness.RecorderPane, _ files: Fixture) async -> [String] {
        let workspace = harness.workspace
        var failures: [String] = []
        let busyMark = codex.log.mark()
        if workspace.startWrapUp(of: codex.pane, current: .some(nil), transcripts: [files.busy], codexHome: files.home) != .refused {
            failures.append("busy Codex not refused")
        }
        await harness.pause(.milliseconds(600))
        if !codex.log.bytes(since: busyMark).isEmpty { failures.append("typed into a busy Codex") }
        let mark = codex.log.mark()
        if workspace.startWrapUp(of: codex.pane, current: .some(nil), transcripts: [files.idle], codexHome: files.home) != .started {
            failures.append("idle Codex not started")
        }
        let promised = Array(AppConstants.WrapUp.request(closing: true).utf8)
        let typed = await harness.settledBytes(codex.log, since: mark, expectingAtLeast: promised.count + 1)
        if typed != promised + [0x0D] { failures.append("typed \(typed.count) bytes, not the request with the close") }
        guard let pending = workspace.wrapUps[codex.pane.id], case let .codexTranscript(watch) = pending.tracker else {
            return failures + ["not tracked by Codex's transcript"]
        }
        if watch.owned != [CodexTranscript.canonical(files.idle)] || watch.offsets != CodexTranscript.sizes([files.idle, files.server]) {
            failures.append("watching \(watch.owned) \(watch.offsets.count) files")
        }
        let asked = pending.requestedAt
        let at = { (seconds: TimeInterval) in asked.addingTimeInterval(seconds).timeIntervalSince(Self.base) }
        let open = { workspace.panes.contains { $0.id == codex.pane.id } }
        Self.append([Self.started("w", at(1)), Self.user(AppConstants.WrapUp.request(closing: true), at(1))], to: files.idle)
        workspace.checkWrapUps(now: asked.addingTimeInterval(30))
        if !open() { failures.append("closed mid-turn") }
        Self.append([Self.complete("w", "세션 종료 절차를 완료했습니다.", at(40))], to: files.idle)
        workspace.checkWrapUps(now: asked.addingTimeInterval(41))
        if !open() { failures.append("closed before the finish settled") }
        workspace.checkWrapUps(now: asked.addingTimeInterval(40 + TimeInterval(AppConstants.WrapUp.settleSeconds)))
        if open() || workspace.wrapUps[codex.pane.id] != nil { failures.append("not closed after the answered turn") }
        return failures
    }

    /// A first-turn Codex (no transcript yet) is watched; a failed turn
    /// stops the watch and leaves the terminal.
    private func failedTurnStaysOpen(_ pane: TerminalPane, home: URL) -> [String] {
        let workspace = harness.workspace
        guard workspace.startWrapUp(of: pane, current: .some(nil), transcripts: [], codexHome: home) == .started else {
            return ["first-turn Codex not started"]
        }
        workspace.checkWrapUps(now: Date().addingTimeInterval(5), codexLookup: { _ in .failed })
        let open = workspace.panes.contains { $0.id == pane.id }
        return open && workspace.wrapUps[pane.id] == nil ? [] : ["failed turn: closed, or still waiting"]
    }

    /// An agent nothing reports on gets the request without the close.
    private func typesOnly(_ bare: SelfTestHarness.RecorderPane) async -> [String] {
        let workspace = harness.workspace
        let mark = bare.log.mark()
        var failures: [String] = []
        if workspace.startWrapUp(of: bare.pane, current: .some(nil)) != .sentWithoutClose || workspace.wrapUps[bare.pane.id] != nil {
            failures.append("no aib state (Claude): not typed-only")
        }
        let plain = Array(AppConstants.WrapUp.request(closing: false).utf8)
        let typed = await harness.settledBytes(bare.log, since: mark, expectingAtLeast: plain.count + 1)
        if typed != plain + [0x0D] { failures.append("typed-only request promised a close (\(typed.count) bytes)") }
        return failures
    }

    /// A Codex whose transcript a process outside the terminal writes (a
    /// background server): another barrack's wrap-up there does not close
    /// it; its own, in its folder, does.
    private func closesFromServerTranscript(_ pane: TerminalPane, server: URL, home: URL) async -> [String] {
        let workspace = harness.workspace
        guard workspace.startWrapUp(of: pane, current: .some(nil), transcripts: [], codexHome: home) == .started,
              let pending = workspace.wrapUps[pane.id], case let .codexTranscript(watch) = pending.tracker, let cwd = watch.cwd
        else { return ["served Codex not started with a folder"] }
        await harness.pause(AppConstants.WrapUp.submitDelay + .milliseconds(200))
        let at = { (seconds: TimeInterval) in pending.requestedAt.addingTimeInterval(seconds).timeIntervalSince(Self.base) }
        let request = AppConstants.WrapUp.request(closing: true)
        Self.append([Self.started("o", at(1)), Self.context("o", cwd + "-other", at(1)), Self.user(request, at(1)),
                     Self.complete("o", "다른 배럭 정리 완료", at(10))], to: server)
        workspace.checkWrapUps(now: pending.requestedAt.addingTimeInterval(20))
        var failures: [String] = []
        if !workspace.panes.contains(where: { $0.id == pane.id }) { failures.append("closed by another barrack's wrap-up") }
        Self.append([Self.started("w", at(21)), Self.context("w", cwd, at(21)), Self.user(request, at(21)),
                     Self.complete("w", "세션 종료 절차를 완료했습니다.", at(40))], to: server)
        workspace.checkWrapUps(now: pending.requestedAt.addingTimeInterval(40 + TimeInterval(AppConstants.WrapUp.settleSeconds)))
        if workspace.panes.contains(where: { $0.id == pane.id }) || workspace.wrapUps[pane.id] != nil {
            failures.append("not closed by its own wrap-up in a server's transcript")
        }
        return failures
    }

    private static func append(_ lines: [String], to file: URL) {
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
    }

    private static func fail(_ id: String, _ reason: String, _ start: ContinuousClock.Instant) -> TestResult {
        .make(id, "Codex 정리하고 닫기", status: .fail, cause: .app, evidence: ["reason": reason], startedAt: start)
    }
}
