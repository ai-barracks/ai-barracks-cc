import Foundation

/// ⌘K search across every barrack, with CC v1.6.1 `search_all` semantics:
/// sessions, wiki topics, RULES, SOUL and GROWTH; case-insensitive line
/// match; three hits per file; 120-character snippets; queries shorter than
/// two characters return nothing; fifty hits at most.
struct SearchHit: Identifiable, Sendable, Equatable {
    enum Source: String, Sendable { case session, wiki, rules, config }

    let barrackID: String
    let barrackName: String
    let source: Source
    let title: String
    let snippet: String
    let file: URL

    var id: String { "\(file.path)#\(snippet)" }
}

enum SearchIndex {
    static let snippetLimit = 120
    static let hitsPerFile = 3
    static let maxHits = 50

    static func search(_ query: String, in barracks: [Barrack]) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= 2 else { return [] }
        var hits: [SearchHit] = []
        for barrack in barracks {
            for (source, file, title) in files(of: barrack) {
                for snippet in matches(in: file, needle) {
                    hits.append(SearchHit(barrackID: barrack.id, barrackName: barrack.name, source: source,
                                          title: title, snippet: snippet, file: file))
                }
            }
        }
        return Array(hits.prefix(maxHits))
    }

    private static func files(of barrack: Barrack) -> [(SearchHit.Source, URL, String)] {
        let root = barrack.url
        let listing = { (directory: String) -> [URL] in
            let url = root.appendingPathComponent(directory)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            return names.filter { $0.hasSuffix(".md") }.sorted().map { url.appendingPathComponent($0) }
        }
        let sessions = listing("sessions").map { (SearchHit.Source.session, $0, $0.deletingPathExtension().lastPathComponent) }
        let wiki = listing("wiki/topics").map { (SearchHit.Source.wiki, $0, $0.deletingPathExtension().lastPathComponent) }
        let fixed: [(SearchHit.Source, String)] = [(.rules, "RULES.md"), (.config, "SOUL.md"), (.config, "GROWTH.md")]
        return sessions + wiki + fixed.map { ($0.0, root.appendingPathComponent($0.1), $0.1) }
    }

    static func matches(in file: URL, _ needle: String) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var found: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where line.lowercased().contains(needle) {
            found.append(snippet(String(line)))
            if found.count >= hitsPerFile { break }
        }
        return found
    }

    static func snippet(_ line: String) -> String {
        line.count > snippetLimit ? String(line.prefix(snippetLimit)) + "..." : line
    }
}
