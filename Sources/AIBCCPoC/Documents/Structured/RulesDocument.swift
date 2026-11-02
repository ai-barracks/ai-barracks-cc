import Foundation

/// Port of CC v1.6.1 `rulesDocument.ts`: RULES.md as three managed bullet
/// lists. Patching touches only the lists that changed and fails closed
/// when the file's shape is ambiguous; everything else stays byte-identical.
struct RulesData: Equatable {
    var mustAlways: [String] = []
    var mustNever: [String] = []
    var learned: [String] = []
}

enum RulesDocument {
    enum Field: String, CaseIterable { case mustAlways = "Must Always", mustNever = "Must Never", learned = "Learned" }

    struct Failure: Error, Equatable {
        let field: Field
        let reason: MarkdownPatch.Failure
    }

    static let template = "# Rules\n\n## Must Always\n\n## Must Never\n\n## Learned\n"

    static func parse(_ raw: String) -> RulesData {
        var data = RulesData()
        for section in MarkdownPatch.sections(raw) where section.level == 2 {
            switch section.heading {
            case Field.mustAlways.rawValue: data.mustAlways = managedBullets(section.raw)
            case Field.mustNever.rawValue: data.mustNever = managedBullets(section.raw)
            case Field.learned.rawValue: data.learned = managedBullets(section.raw)
            default: break
            }
        }
        return data
    }

    static func patch(_ raw: String, to next: RulesData) -> Result<String, Failure> {
        let effective = raw.isEmpty ? template : raw
        let previous = parse(effective)
        var current = effective
        for field in Field.allCases where list(previous, field) != list(next, field) {
            switch patchSection(current, field, old: list(previous, field), new: list(next, field)) {
            case let .success(updated): current = updated
            case let .failure(failure): return .failure(failure)
            }
        }
        return .success(current)
    }

    static func list(_ data: RulesData, _ field: Field) -> [String] {
        switch field {
        case .mustAlways: data.mustAlways
        case .mustNever: data.mustNever
        case .learned: data.learned
        }
    }

    private static func managedBullets(_ sectionRaw: String) -> [String] {
        var fence = MarkdownPatch.Fence()
        return MarkdownPatch.splitLines(sectionRaw).dropFirst().compactMap { line in
            let content = MarkdownPatch.stripEol(line)
            if fence.consume(content) || fence.inside { return nil }
            return Regex.capture(#"^[ \t]*[-*+][ \t]+(.*)$"#, content)?[1]
        }
    }

    private static func patchSection(_ raw: String, _ field: Field, old: [String], new: [String]) -> Result<String, Failure> {
        let all = MarkdownPatch.sections(raw)
        let matching = all.indices.filter { all[$0].level == 2 && all[$0].heading == field.rawValue }
        guard let index = matching.first else { return .failure(Failure(field: field, reason: .sectionNotFound)) }
        guard matching.count == 1 else { return .failure(Failure(field: field, reason: .multipleSections)) }
        let lines = MarkdownPatch.splitLines(all[index].raw)
        let runs = MarkdownPatch.bulletRuns(lines, from: 1)
        guard runs.count <= 1 else { return .failure(Failure(field: field, reason: .multipleBulletRuns)) }
        if runs.count == 1 {
            return MarkdownPatch.patchBulletRun(raw, level: 2, heading: field.rawValue, bullets: new)
                .mapError { Failure(field: field, reason: $0 == .noBulletRun ? .multipleBulletRuns : $0) }
        }
        // No run: only fill a section that was empty.
        guard old.isEmpty else { return .failure(Failure(field: field, reason: .multipleBulletRuns)) }
        guard !new.isEmpty else { return .success(raw) }
        let eol = MarkdownPatch.detectEol(raw)
        let heading = lines.first ?? ""
        let fixedHeading = MarkdownPatch.lineEol(heading).isEmpty ? heading + eol : heading
        let patched = [fixedHeading] + new.map { "- \($0)\(eol)" } + Array(lines.dropFirst())
        var updated = all
        updated[index] = MarkdownPatch.Section(level: 2, heading: field.rawValue, raw: patched.joined())
        return .success(updated.map(\.raw).joined())
    }
}
