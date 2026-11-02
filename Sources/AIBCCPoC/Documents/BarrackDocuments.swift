import Foundation

/// Where the fixed viewers find their documents in a barrack.
enum BarrackDocuments {
    /// `skills/<name>/SKILL.md` (aib's skill layout).
    /// What each fixed barrack file is for (v1 FilesTab descriptions).
    static func role(of name: String) -> String? {
        switch name {
        case "SOUL.md": "에이전트의 이름·전문성·성격"
        case "GROWTH.md": "성장 트리거와 지식 기록 규칙"
        case "RULES.md": "세션에서 배운 행동 규칙(에이전트가 덧붙임)"
        case "agent.yaml": "배럭 메타데이터·모델·aib 버전"
        default: nil
        }
    }

    /// The catalog's SKILL.md files (same symlink rules as the Skills view).
    static func skills(in root: URL) -> [URL] {
        SkillFiles.list(in: root).map(\.file)
    }

    static func firstWikiTopic(in root: URL) -> URL? {
        let directory = root.appendingPathComponent("wiki/topics")
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".md") }.sorted().first.map { directory.appendingPathComponent($0) }
    }

    /// Council outputs kept in `resources/council`, newest first; prompts
    /// and run logs are inputs, not minutes.
    static func councilMinutes(in root: URL) -> [URL] {
        let directory = root.appendingPathComponent("resources/council")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let modified = { (url: URL) in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return files.filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasSuffix("-prompt.md") }
            .sorted { modified($0) > modified($1) }
    }

    /// `---` YAML frontmatter → "**name** — description" so a skill reads
    /// as a document, not as configuration.
    static func frontmatterAsHeader(_ text: String) -> String {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex)
        else { return text }
        let yaml = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
        let fields = Dictionary(yaml.split(separator: "\n").compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return (String(line[..<colon]), value)
        }, uniquingKeysWith: { first, _ in first })
        let header = [fields["name"].map { "**\($0)**" }, fields["description"]].compactMap { $0 }.joined(separator: " — ")
        return (header.isEmpty ? "" : "> \(header)\n\n") + text[end.upperBound...]
    }
}
