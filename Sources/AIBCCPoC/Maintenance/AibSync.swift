import Foundation

/// `aib sync` from the GUI. After a skill change it rewrites the CLAUDE.md
/// skills catalog and the `.claude/skills`, `.agents/skills` links (v1
/// useSkillCrud); after a barrack document save a dry run validates the
/// file (v1 FilesTab). A failure never undoes the file change.
enum AibSync {
    enum Outcome: Equatable {
        case ok
        case failed(String)
    }

    typealias Runner = @Sendable (URL) async -> Outcome

    static let apply = runner()
    /// Validation only: a dry run writes nothing, not even the registry.
    static let check = runner(dryRun: true)

    /// `registry` redirects aib's barrack registry (self-tests): a real
    /// sync also re-registers the barrack in ~/.aib/barracks.json.
    static func runner(dryRun: Bool = false, registry: String? = nil) -> Runner {
        let prefix = registry.map { "AIB_REGISTRY=\(AgentLauncher.shellQuote($0)) " } ?? ""
        let command = "\(prefix)aib sync \(dryRun ? "--dry-run " : "")."
        return { barrack in await run(command, in: barrack) }
    }

    private static func run(_ command: String, in barrack: URL) async -> Outcome {
        let result = await ProcessOutput.runWithStatus(URL(fileURLWithPath: "/bin/zsh"), ["-lc", command], in: barrack.path)
        guard result.status != 0 else { return .ok }
        let lines = MaintenanceScanner.lines(result.output)
        let reason = lines.first { $0.localizedCaseInsensitiveContains("error") || $0.contains("✗") } ?? lines.last
        return .failed(String((reason ?? "종료 코드 \(result.status)").prefix(240)))
    }
}
