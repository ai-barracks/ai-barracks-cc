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

    /// Lists the form cannot save in this file (probed with a dummy edit),
    /// so the editor can say so before the user types.
    static func blocked(_ raw: String) -> [Failure] {
        Field.allCases.compactMap { field in
            var probe = parse(raw)
            switch field {
            case .mustAlways: probe.mustAlways.append("probe")
            case .mustNever: probe.mustNever.append("probe")
            case .learned: probe.learned.append("probe")
            }
            if case let .failure(failure) = patch(raw, to: probe) { return failure }
            return nil
        }
    }

    static func merge(base: RulesData, mine: RulesData, theirs: RulesData) -> RulesData? {
        guard let always = StructuredEditing.pick(base.mustAlways, mine.mustAlways, theirs.mustAlways),
              let never = StructuredEditing.pick(base.mustNever, mine.mustNever, theirs.mustNever),
              let learned = StructuredEditing.pick(base.learned, mine.learned, theirs.learned) else { return nil }
        return RulesData(mustAlways: always, mustNever: never, learned: learned)
    }

    static func list(_ data: RulesData, _ field: Field) -> [String] {
        switch field {
        case .mustAlways: data.mustAlways
        case .mustNever: data.mustNever
        case .learned: data.learned
        }
    }

    private static func managedBullets(_ sectionRaw: String) -> [String] {
        MarkdownPatch.managedBullets(sectionRaw)
    }

    private static func patchSection(_ raw: String, _ field: Field, old: [String], new: [String]) -> Result<String, Failure> {
        MarkdownPatch.patchListSection(raw, level: 2, heading: field.rawValue, old: old, new: new)
            .mapError { Failure(field: field, reason: $0) }
    }
}
