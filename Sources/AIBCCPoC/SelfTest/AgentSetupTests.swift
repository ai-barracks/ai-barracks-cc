import Foundation

/// A new Mac's first run (2026-11-25): a newer aib is offered (AU-01a), and
/// a Codex that reports nothing gets the right hint (CH-01a).
@MainActor
enum AgentSetupTests {
    static func run() async -> [TestResult] {
        [await aibUpdate(), codexHint()]
    }

    /// AU-01a: GitHub's aib release vs `aib version`; offered only when newer.
    static func aibUpdate() async -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let version = { (text: String) in ReleaseVersion(text) }
        if AibUpdate.parse(Data(#"{"tag_name":"v1.6.2","name":"x"}"#.utf8)) != version("1.6.2") { failures.append("tag not read") }
        if AibUpdate.parse(Data("{}".utf8)) != nil || AibUpdate.parse(Data("oops".utf8)) != nil { failures.append("a version from nothing") }
        let cases: [(String?, String?, String?)] = [
            ("1.6.1", "1.6.2", "1.6.2"), ("1.6.2", "1.6.2", nil), ("1.10.0", "1.9.9", nil), (nil, "1.6.2", nil), ("1.6.1", nil, nil),
        ]
        for (installed, newest, expected) in cases {
            let got = AibUpdate.offer(installed: installed.flatMap(version), newest: newest.flatMap(version))
            if got != expected.flatMap(version) { failures.append("offer \(installed ?? "-")→\(newest ?? "-"): \(got.map(\.description) ?? "nil")") }
        }
        if AibUpdate.command != "aib update" { failures.append("button runs \(AibUpdate.command)") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-au-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feed = directory.appendingPathComponent("latest.json")
        try? Data(#"{"tag_name":"v99.0.0"}"#.utf8).write(to: feed)
        let model = AibUpdate.shared
        await model.check(feed: feed)
        if model.newest != version("99.0.0") { failures.append("feed not read: \(model.newest.map(\.description) ?? "nil")") }
        if model.installed != nil, model.available != version("99.0.0") { failures.append("newer aib not offered") }
        return .make("AU-01a", "aib 업데이트 감지: GitHub 최신 aib가 설치본보다 새로울 때만 사이드바에서 'aib update' 제안",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | "), "installed": model.installed?.description ?? "none"], startedAt: start)
    }

    /// CH-01a: aib's Codex hooks found in the user's or the barrack's
    /// hooks.json; the hint says trust (installed) or install (missing).
    static func codexHint() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-ch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("codex-home"), barrack = directory.appendingPathComponent("barrack")
        for folder in [home, barrack.appendingPathComponent(".codex")] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let hooks = { (command: String) in
            Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(command)"}]}]}}"#.utf8)
        }
        let user = home.appendingPathComponent("hooks.json"), project = barrack.appendingPathComponent(".codex/hooks.json")
        if CodexHookHint.installed(barrackPath: barrack.path, home: home) { failures.append("no files read as installed") }
        try? hooks("user hook").write(to: user)
        try? Data("{broken".utf8).write(to: project)
        if CodexHookHint.installed(barrackPath: barrack.path, home: home) { failures.append("other hooks read as aib's") }
        try? hooks(CodexHookHint.command).write(to: project)
        if !CodexHookHint.installed(barrackPath: barrack.path, home: home) { failures.append("barrack hooks missed") }
        try? FileManager.default.removeItem(at: project)
        try? hooks(CodexHookHint.command).write(to: user)
        if !CodexHookHint.installed(barrackPath: nil, home: home) { failures.append("user hooks missed") }
        if !CodexHookHint.message(installed: true).body.contains("/hooks") { failures.append("installed: no /hooks trust hint") }
        if !CodexHookHint.message(installed: false).body.contains("aib sync") { failures.append("missing: no install hint") }
        return .make("CH-01a", "상태를 안 알리는 Codex 안내: aib hook이 있으면 /hooks 신뢰, 없으면 aib sync 설치",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }
}
