import Foundation

/// Codex r5 (2026-11-04) global-state findings, each as a regression.
@MainActor
struct ReviewR5Suite {
    private final class Spans: @unchecked Sendable {
        private let lock = NSLock()
        private var spans: [(Date, Date)] = []
        func add(_ start: Date, _ end: Date) { lock.withLock { spans.append((start, end)) } }
        var all: [(Date, Date)] { lock.withLock { spans } }
    }

    func run() async -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        // Inherited GIT_DIR/GIT_WORK_TREE/config injection beat `-C`.
        let env = GitRepository.environment(inherited: ["GIT_DIR": "/real/.git", "GIT_WORK_TREE": "/real", "GIT_CONFIG_COUNT": "1",
                                                        "GIT_CONFIG_KEY_0": "core.worktree", "PATH": "/bin", "GIT_CONFIG_GLOBAL": "/home/x"],
                                            extra: ["GIT_CONFIG_GLOBAL": "/dev/null"])
        if env["GIT_DIR"] != nil || env["GIT_WORK_TREE"] != nil || env["GIT_CONFIG_COUNT"] != nil || env["GIT_CONFIG_KEY_0"] != nil
            || env["PATH"] != "/bin" || env["GIT_CONFIG_GLOBAL"] != "/dev/null" || env["GIT_TERMINAL_PROMPT"] != "0" { failures.append("git env") }
        // Overlapping aib writes raced aib's lock-free registry update.
        let spans = Spans()
        async let first: Void = AibWriteQueue.run { let s = Date(); try? await Task.sleep(for: .milliseconds(200)); spans.add(s, Date()) }
        async let second: Void = AibWriteQueue.run { let s = Date(); try? await Task.sleep(for: .milliseconds(200)); spans.add(s, Date()) }
        _ = await (first, second)
        let ordered = spans.all.sorted { $0.0 < $1.0 }
        if ordered.count != 2 || ordered[1].0 < ordered[0].1 { failures.append("aib writes overlapped") }
        // A real empty registry (last barrack removed) vs a damaged one.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-r5-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = directory.appendingPathComponent("barracks.json")
        let read = { (text: String?) -> [Barrack]? in
            try? FileManager.default.removeItem(at: registry)
            if let text { try? Data(text.utf8).write(to: registry) }
            return BarrackRegistry.read(from: registry.path)
        }
        if read("[]") != [] || read("") != nil || read("{broken") != nil || read(nil) != nil { failures.append("registry read") }
        // aib's seeded skills come back after a sync.
        let script = "#!/bin/bash\nAIB_VERSION=1.6.0\nTEMPLATE_DIR=\"\(directory.path)/templates\"\n"
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("templates/skills/council"), withIntermediateDirectories: true)
        try? Data("---\nname: council\n---\n".utf8).write(to: directory.appendingPathComponent("templates/skills/council/SKILL.md"))
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("templates/skills/empty"), withIntermediateDirectories: true)
        guard let templates = AibTemplates.templateDirectory(fromScript: script) else {
            return check(["template dir"] + failures, start)
        }
        if AibTemplates.skills(in: templates) != ["council"] { failures.append("template skills") }
        if AibTemplates.templateDirectory(fromScript: "TEMPLATE_DIR=\"$HOME/x\"\n") != nil { failures.append("unexpanded path accepted") }
        return check(failures, start)
    }

    private func check(_ failures: [String], _ start: ContinuousClock.Instant) -> TestResult {
        .make("R5-01a", "Codex r5 전역 상태: 상속 GIT_DIR 무시·aib 쓰기 직렬화·빈 레지스트리와 손상 구분·aib 기본 skill 식별",
              status: failures.isEmpty ? .pass : .fail, cause: .app, evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }
}
