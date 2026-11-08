import Foundation

/// One row of `wiki/Index.md`'s topic table (v1 get_wiki_index).
struct WikiTopicEntry: Equatable, Sendable {
    let name: String
    /// As linked in the table, e.g. `topics/foo.md`.
    let file: String
    let updated: String
    let summary: String
}

/// What the Wiki list shows besides file names (Codex parity audit P10):
/// the topic name, summary and date from Index.md's table, and the latest
/// lines of Log.md. A table that cannot be read leaves the file list as is
/// and says so; the raw Index stays readable.
struct WikiIndex: Equatable, Sendable {
    /// nil: Index.md has no readable topic table.
    let topics: [WikiTopicEntry]?
    let recentChanges: [String]

    static let recentLimit = 5

    static func load(barrack root: URL) -> WikiIndex {
        let wiki = root.appendingPathComponent("wiki")
        let index = (try? String(contentsOf: wiki.appendingPathComponent("Index.md"), encoding: .utf8)) ?? ""
        let log = (try? String(contentsOf: wiki.appendingPathComponent("Log.md"), encoding: .utf8)) ?? ""
        return WikiIndex(topics: parse(index), recentChanges: recentChanges(log))
    }

    /// The first table whose header starts with "Topic"; rows run to the
    /// first line that is not a table row. The summary keeps any further
    /// `|` (it is the last column).
    static func parse(_ text: String) -> [WikiTopicEntry]? {
        var entries: [WikiTopicEntry] = []
        var inTable = false
        var found = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !inTable {
                if line.hasPrefix("|"), cells(line).first?.lowercased() == "topic" {
                    inTable = true
                    found = true
                }
                continue
            }
            guard line.hasPrefix("|") else {
                if found, !entries.isEmpty || !line.isEmpty { break }
                continue
            }
            let columns = cells(line)
            guard columns.count >= 4, !columns[0].allSatisfy({ "-: ".contains($0) }) else { continue }
            let summary = columns[3...].joined(separator: " | ")
            entries.append(WikiTopicEntry(name: columns[0], file: link(columns[1]), updated: columns[2], summary: summary))
        }
        return found ? entries : nil
    }

    /// Newest first (Log.md is append-at-top): the first `- ` lines.
    static func recentChanges(_ text: String, limit: Int = recentLimit) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .prefix(limit)
            .map { String($0.dropFirst(2)) }
    }

    /// The entry for a topic file, matched by its file name.
    func entry(for file: URL) -> WikiTopicEntry? {
        topics?.first { URL(fileURLWithPath: $0.file).lastPathComponent == file.lastPathComponent }
    }

    /// Topic files in Index order, then the ones the Index does not list.
    func ordered(_ files: [URL]) -> [URL] {
        guard let topics else { return files }
        let rank = Dictionary(topics.enumerated().map { (URL(fileURLWithPath: $1.file).lastPathComponent, $0) },
                              uniquingKeysWith: { first, _ in first })
        return files.sorted {
            switch (rank[$0.lastPathComponent], rank[$1.lastPathComponent]) {
            case let (left?, right?): left < right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): $0.lastPathComponent < $1.lastPathComponent
            }
        }
    }

    private static func cells(_ line: String) -> [String] {
        var parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// `[name](topics/x.md)` → `topics/x.md`; plain text stays.
    private static func link(_ cell: String) -> String {
        guard let open = cell.range(of: "]("), let close = cell.range(of: ")", range: open.upperBound..<cell.endIndex) else { return cell }
        return String(cell[open.upperBound..<close.lowerBound])
    }
}
