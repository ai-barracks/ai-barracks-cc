import Foundation

/// v1 BarrackOverview facts for one barrack, read from its files: session
/// records, Wiki topics, rules per section, skills, the SOUL summary and
/// agent.yaml (models, aib_version).
struct BarrackOverview: Equatable {
    var sessions = 0
    var wikiTopics = 0
    var skills = 0
    var rules = RulesData()
    var soul = SoulData()
    var agent = AgentConfig()

    var ruleCount: Int { rules.mustAlways.count + rules.mustNever.count + rules.learned.count }

    static func load(_ root: URL) -> BarrackOverview {
        let read = { (name: String) in (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        let topics = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("wiki/topics").path)) ?? []
        return BarrackOverview(sessions: SessionRecords.count(barrackPath: root.path),
                               wikiTopics: topics.filter { $0.hasSuffix(".md") }.count,
                               skills: SkillFiles.list(in: root).count,
                               rules: RulesDocument.parse(read("RULES.md")),
                               soul: SoulDocument.parse(read("SOUL.md")),
                               agent: AgentYamlDocument.parse(read("agent.yaml")))
    }

    /// v1 compares agent.yaml's aib_version with the installed CLI.
    func isOutdated(cliVersion: String) -> Bool {
        !cliVersion.isEmpty && !agent.aibVersion.isEmpty && agent.aibVersion != cliVersion
    }
}
