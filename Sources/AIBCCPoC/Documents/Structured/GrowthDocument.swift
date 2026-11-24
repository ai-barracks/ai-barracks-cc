import Foundation

/// Port of CC v1.6.1 `growthDocument.ts`: the GROWTH.md Decision Table
/// (header row containing "세션 중 이벤트") and the "NOT growth-worthy"
/// bullet list. Only the changed part is rewritten; an ambiguous shape
/// fails closed.
///
/// Deliberate difference from v1: parsing stops a table at a blank line and
/// skips only the separator row, the same rows patching replaces — v1
/// parsed rows after a blank line (or rows containing "---") that its patch
/// did not treat as table rows, so a save could duplicate or drop them.
struct DecisionRow: Equatable {
    var event = ""
    var location = ""
    var example = ""
}

struct GrowthData: Equatable {
    var decisionTable: [DecisionRow] = []
    var notGrowthWorthy: [String] = []
}

enum GrowthDocument {
    enum Field: String, CaseIterable { case decisionTable = "Decision Table", notGrowthWorthy = "NOT growth-worthy" }

    enum Reason: Error, Equatable {
        case headerNotFound, multipleHeaders, separatorNotFound, malformedRow
        case anchorNotFound, multipleAnchors, multipleBulletRuns, nestedBullets
    }

    struct Failure: Error, Equatable {
        let field: Field
        let reason: Reason
    }

    static func parse(_ raw: String) -> GrowthData {
        var data = GrowthData()
        var table = TableState.outside
        var inNotGrowth = false
        var fence = MarkdownPatch.Fence()
        for line in MarkdownPatch.splitLines(raw) {
            let content = MarkdownPatch.stripEol(line)
            if fence.consume(content) || fence.inside { continue }
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if isHeader(trimmed) {
                table = .expectSeparator
                inNotGrowth = false
                continue
            }
            if table != .outside {
                if trimmed.hasPrefix("|") {
                    let isSeparator = table == .expectSeparator && trimmed.contains("---")
                    if !isSeparator, let row = row(trimmed) { data.decisionTable.append(row) }
                    table = .rows
                    continue
                }
                table = .outside
            }
            if isAnchor(trimmed) {
                inNotGrowth = true
                continue
            }
            if inNotGrowth, trimmed.hasPrefix("- ") {
                data.notGrowthWorthy.append(String(trimmed.dropFirst(2)))
                continue
            }
            if inNotGrowth, trimmed.hasPrefix("##") { inNotGrowth = false }
        }
        return data
    }

    static func patch(_ raw: String, to next: GrowthData) -> Result<String, Failure> {
        let previous = parse(raw)
        var current = raw
        if previous.decisionTable != next.decisionTable {
            switch patchTable(current, next.decisionTable) {
            case let .success(updated): current = updated
            case let .failure(reason): return .failure(Failure(field: .decisionTable, reason: reason))
            }
        }
        if previous.notGrowthWorthy != next.notGrowthWorthy {
            switch patchNotGrowth(current, old: previous.notGrowthWorthy, new: next.notGrowthWorthy) {
            case let .success(updated): current = updated
            case let .failure(reason): return .failure(Failure(field: .notGrowthWorthy, reason: reason))
            }
        }
        return .success(current)
    }

    /// Parts the form cannot save in this file (probed with a dummy edit),
    /// e.g. a customized GROWTH.md with a second Decision Table.
    static func blocked(_ raw: String) -> [Failure] {
        var row = parse(raw)
        row.decisionTable.append(DecisionRow(event: "probe", location: "probe", example: "probe"))
        var bullet = parse(raw)
        bullet.notGrowthWorthy.append("probe")
        return [row, bullet].compactMap { probe in
            if case let .failure(failure) = patch(raw, to: probe) { return failure }
            return nil
        }
    }

    static func merge(base: GrowthData, mine: GrowthData, theirs: GrowthData) -> GrowthData? {
        guard let table = StructuredEditing.pick(base.decisionTable, mine.decisionTable, theirs.decisionTable),
              let list = StructuredEditing.pick(base.notGrowthWorthy, mine.notGrowthWorthy, theirs.notGrowthWorthy) else { return nil }
        return GrowthData(decisionTable: table, notGrowthWorthy: list)
    }

    private enum TableState { case outside, expectSeparator, rows }

    private static func isHeader(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("|") && trimmed.contains("세션 중 이벤트")
    }

    private static func isAnchor(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("**NOT growth-worthy**") || trimmed.contains("기록하지 않을 것")
    }

    /// The cells of a table line, split at unescaped pipes (`\|` stays in
    /// its cell) without the outer border. v1 split on every pipe and kept
    /// "at least 3" cells, so an escaped pipe or a fourth column was lost on
    /// save (r5); a row must now have exactly three.
    static func cells(_ trimmed: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for char in trimmed {
            if escaped {
                current.append(char)
                escaped = false
            } else if char == "\\" {
                current.append(char)
                escaped = true
            } else if char == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        cells.append(current)
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells
    }

    /// Text that stays one cell when written between pipes — judged by the
    /// tokenizer that reads it back, so the form and the file agree on `\\|`
    /// (Codex r6: the form's own regex let `A\\|B` through as one cell).
    static func isCellText(_ text: String) -> Bool {
        cells("| \(text) |").map { $0.trimmingCharacters(in: .whitespaces) } == [text.trimmingCharacters(in: .whitespaces)]
    }

    private static func row(_ trimmed: String) -> DecisionRow? {
        let columns = cells(trimmed)
        guard columns.count == 3 else { return nil }
        let clean = { (index: Int) in columns[index].trimmingCharacters(in: .whitespaces) }
        return DecisionRow(event: clean(0), location: clean(1), example: clean(2))
    }

    /// Indices of non-fenced lines whose trimmed content satisfies `test`.
    private static func unfenced(_ lines: [String], where test: (String) -> Bool) -> [Int] {
        var fence = MarkdownPatch.Fence()
        return lines.indices.filter { index in
            let content = MarkdownPatch.stripEol(lines[index])
            if fence.consume(content) || fence.inside { return false }
            return test(content.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func patchTable(_ raw: String, _ rows: [DecisionRow]) -> Result<String, Reason> {
        let lines = MarkdownPatch.splitLines(raw)
        let headers = unfenced(lines, where: isHeader)
        guard let header = headers.first else { return .failure(.headerNotFound) }
        guard headers.count == 1 else { return .failure(.multipleHeaders) }
        let trimmed = { (index: Int) in MarkdownPatch.stripEol(lines[index]).trimmingCharacters(in: .whitespaces) }
        guard let separator = (header + 1..<lines.count).first(where: { trimmed($0).hasPrefix("|") }),
              trimmed(separator).contains("---") else { return .failure(.separatorNotFound) }
        let dataStart = separator + 1
        var dataEnd = dataStart
        while dataEnd < lines.count, trimmed(dataEnd).hasPrefix("|") { dataEnd += 1 }
        guard cells(trimmed(header)).count == 3, (dataStart..<dataEnd).allSatisfy({ cells(trimmed($0)).count == 3 }) else {
            return .failure(.malformedRow)
        }

        let eol = (dataStart..<dataEnd).map { MarkdownPatch.lineEol(lines[$0]) }.first { !$0.isEmpty }
            ?? nonEmpty(MarkdownPatch.lineEol(lines[separator])) ?? MarkdownPatch.detectEol(raw)
        let hadRows = dataEnd > dataStart
        let lastHadEol = !hadRows || !MarkdownPatch.lineEol(lines[dataEnd - 1]).isEmpty
        let newLines = rows.enumerated().map { offset, row in
            "| \(row.event) | \(row.location) | \(row.example) |" + (offset == rows.count - 1 && !lastHadEol ? "" : eol)
        }
        // Every written row must read back as itself.
        guard zip(rows, newLines).allSatisfy({ row($1.trimmingCharacters(in: .whitespacesAndNewlines)) == $0 }) else {
            return .failure(.malformedRow)
        }
        var head = Array(lines[..<dataStart])
        if !hadRows, !rows.isEmpty, MarkdownPatch.lineEol(lines[separator]).isEmpty { head[separator] += eol }
        return .success((head + newLines + Array(lines[dataEnd...])).joined())
    }

    private static func patchNotGrowth(_ raw: String, old: [String], new: [String]) -> Result<String, Reason> {
        let lines = MarkdownPatch.splitLines(raw)
        let anchors = unfenced(lines, where: isAnchor)
        guard let anchor = anchors.first else { return .failure(.anchorNotFound) }
        guard anchors.count == 1 else { return .failure(.multipleAnchors) }
        let runs = notGrowthRuns(lines, after: anchor)
        guard runs.count <= 1 else { return .failure(.multipleBulletRuns) }
        if let run = runs.first {
            let indents = Set(lines[run].map { MarkdownPatch.stripEol($0).prefix { $0 == " " || $0 == "\t" } })
            guard indents.count == 1, !MarkdownPatch.hasHangingContent(lines, after: run) else { return .failure(.nestedBullets) }
            let eol = lines[run].map(MarkdownPatch.lineEol).first { !$0.isEmpty } ?? MarkdownPatch.detectEol(raw)
            let lastHadEol = !MarkdownPatch.lineEol(lines[run.upperBound - 1]).isEmpty
            let bullets = new.enumerated().map { offset, item in "- \(item)" + (offset == new.count - 1 && !lastHadEol ? "" : eol) }
            return .success((Array(lines[..<run.lowerBound]) + bullets + Array(lines[run.upperBound...])).joined())
        }
        guard old.isEmpty else { return .failure(.multipleBulletRuns) }
        guard !new.isEmpty else { return .success(raw) }
        let eol = nonEmpty(MarkdownPatch.lineEol(lines[anchor])) ?? MarkdownPatch.detectEol(raw)
        var head = Array(lines[...anchor])
        if MarkdownPatch.lineEol(lines[anchor]).isEmpty { head[anchor] += eol }
        return .success((head + new.map { "- \($0)\(eol)" } + Array(lines[(anchor + 1)...])).joined())
    }

    /// "- " bullet runs after the anchor, up to the next heading; fences
    /// and any other line end a run.
    private static func notGrowthRuns(_ lines: [String], after anchor: Int) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var fence = MarkdownPatch.Fence()
        var runStart: Int?
        var index = anchor + 1
        let close = { (end: Int) in
            if let start = runStart { runs.append(start..<end) }
            runStart = nil
        }
        while index < lines.count {
            let content = MarkdownPatch.stripEol(lines[index])
            if fence.consume(content) || fence.inside {
                close(index)
            } else {
                let trimmed = content.trimmingCharacters(in: .whitespaces)
                if Regex.matches(#"^#{1,6}(?:\s|$)"#, trimmed) { break }
                if trimmed.hasPrefix("- ") {
                    runStart = runStart ?? index
                } else {
                    close(index)
                }
            }
            index += 1
        }
        close(index)
        return runs
    }

    private static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }
}
