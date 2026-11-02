import Foundation

/// `aib sync` after a skill change (v1 useSkillCrud): it rewrites the
/// CLAUDE.md skills catalog and the `.claude/skills`, `.agents/skills`
/// links. A failed sync never undoes the file change; the view offers a retry.
enum SkillSync {
    enum Outcome: Equatable {
        case ok
        case failed(String)
    }

    typealias Runner = @Sendable (URL) async -> Outcome

    static let aib = runner()

    /// `registry` redirects aib's barrack registry (self-tests): a real
    /// sync also re-registers the barrack in ~/.aib/barracks.json.
    static func runner(registry: String? = nil) -> Runner {
        let prefix = registry.map { "AIB_REGISTRY=\(AgentLauncher.shellQuote($0)) " } ?? ""
        return { barrack in await run("\(prefix)aib sync .", in: barrack) }
    }

    private static func run(_ command: String, in barrack: URL) async -> Outcome {
        let result = await ProcessOutput.runWithStatus(URL(fileURLWithPath: "/bin/zsh"), ["-lc", command], in: barrack.path)
        guard result.status != 0 else { return .ok }
        let lines = MaintenanceScanner.lines(result.output)
        let reason = lines.first { $0.localizedCaseInsensitiveContains("error") || $0.contains("✗") } ?? lines.last
        return .failed(String((reason ?? "종료 코드 \(result.status)").prefix(240)))
    }
}
