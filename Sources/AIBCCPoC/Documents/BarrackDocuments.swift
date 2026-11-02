import Foundation

/// Where the fixed viewers find their documents in a barrack.
enum BarrackDocuments {
    /// `skills/<name>/SKILL.md` (aib's skill layout).
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
