import Foundation

/// Barrack add/remove through the real aib (v1 create/remove/refresh) with
/// its registry and the CLI settings `aib init` edits (Claude/Gemini hooks)
/// redirected to temp files; the user's copies must be byte-identical after.
@MainActor
struct BarrackAdminSuite {
    func run() async -> TestResult {
        let start = ContinuousClock.now
        let userFiles = ["/.aib/barracks.json", "/.claude/settings.json", "/.gemini/settings.json"].map { URL(fileURLWithPath: NSHomeDirectory() + $0) }
        let before = userFiles.map { try? Data(contentsOf: $0) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-admin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let registry = scratch.appendingPathComponent("barracks.json")
        try? Data("[]".utf8).write(to: registry)
        // aib never registers temp paths unless forced; the registry is ours.
        let environment = ["AIB_REGISTRY": registry.path, "AIB_REGISTER_FORCE": "1",
                           "AIB_CLAUDE_SETTINGS": scratch.appendingPathComponent("claude-settings.json").path,
                           "AIB_GEMINI_SETTINGS": scratch.appendingPathComponent("gemini-settings.json").path]
        let barrack = scratch.appendingPathComponent("new_barrack")
        var failures: [String] = []
        let created = await BarrackAdmin.create(at: barrack.path, environment: environment)
        let registered = { BarrackRegistry.load(from: registry.path).map { URL(fileURLWithPath: $0.path).standardizedFileURL.path } }
        let path = barrack.resolvingSymlinksInPath().path
        if !created.ok { failures.append("init: \(created.output.suffix(120))") }
        for file in ["agent.yaml", "SOUL.md", "RULES.md", "GROWTH.md", "sessions", "CLAUDE.md", "skills/council/SKILL.md"]
        where !FileManager.default.fileExists(atPath: barrack.appendingPathComponent(file).path) { failures.append("scaffold \(file)") }
        if !registered().contains(where: { $0.hasSuffix("/new_barrack") }) { failures.append("registered \(registered())") }
        if !(await BarrackAdmin.refresh(environment: environment)).ok { failures.append("refresh") }
        let removed = await BarrackAdmin.remove(barrack.path, environment: environment)
        if !removed.ok || registered().contains(where: { $0.hasSuffix("/new_barrack") }) { failures.append("remove \(registered())") }
        if !FileManager.default.fileExists(atPath: barrack.appendingPathComponent("agent.yaml").path) { failures.append("remove deleted files") }
        for (file, old) in zip(userFiles, before) where (try? Data(contentsOf: file)) != old { failures.append("USER FILE CHANGED \(file.path)") }
        return .make("BA-01a", "배럭 추가(aib init+sync: 다른 배럭과 같은 파일·등록)·새로 고침·제거(목록만, 파일 유지) · 사용자 레지스트리·CLI 설정 무변경",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | "), "path": path], startedAt: start)
    }
}
