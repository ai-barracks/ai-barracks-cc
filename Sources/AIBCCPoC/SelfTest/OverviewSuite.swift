import Foundation

/// v1 BarrackOverview facts on a throwaway barrack.
@MainActor
struct OverviewSuite {
    func run() -> TestResult {
        let start = ContinuousClock.now
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-overview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let write = { (path: String, text: String) in
            let url = root.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
        write("sessions/a.md", "# a")
        write("sessions/b.md", "# b")
        write("sessions/b.violations", "x")
        write("wiki/topics/one.md", "# t")
        write("wiki/topics/notes.txt", "x")
        write("RULES.md", DocumentSuite.richRules)
        write("SOUL.md", DocumentSuite.richSoul)
        write("agent.yaml", DocumentSuite.richYaml)
        write("skills/open-pr/SKILL.md", SkillDocument.render(slug: "open-pr", fields: SkillFields(description: "Use when opening a PR"), body: ""))
        let overview = BarrackOverview.load(root)
        var failures: [String] = []
        if overview.sessions != 2 || overview.wikiTopics != 1 || overview.skills != 1 { failures.append("counts \(overview.sessions)/\(overview.wikiTopics)/\(overview.skills)") }
        if overview.ruleCount != 5 || overview.rules.learned.count != 1 { failures.append("rules \(overview.ruleCount)") }
        if overview.soul.name != "Aria" || overview.soul.expertise != ["TypeScript", "React"] { failures.append("soul") }
        if overview.agent.primaryModel != "gpt-5.5" || overview.agent.aibVersion != "1.1" { failures.append("agent") }
        if !overview.isOutdated(cliVersion: "1.6.0") || overview.isOutdated(cliVersion: "1.1") || overview.isOutdated(cliVersion: "") {
            failures.append("outdated rule")
        }
        if BarrackOverview.load(root.appendingPathComponent("missing")) != BarrackOverview() { failures.append("missing barrack") }
        return .make("OV-01a", "배럭 개요 = v1 Overview(세션·Wiki·규칙 A/N/L·Skills·SOUL 요약·모델·aib_version drift)",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }
}
