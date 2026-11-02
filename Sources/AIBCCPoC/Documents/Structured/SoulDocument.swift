import Foundation

/// Port of CC v1.6.1 `soulDocument.ts`: SOUL.md as a name line and four
/// managed bullet lists under H2 headings. Only changed fields are patched;
/// comments, custom sections and fenced code stay byte-identical, and an
/// ambiguous shape fails closed.
struct SoulData: Equatable {
    var name = ""
    var expertise: [String] = []
    var personality: [String] = []
    var coreValues: [String] = []
    var constraints: [String] = []
}

enum SoulDocument {
    enum Field: String, CaseIterable {
        case name = "Name", expertise = "Expertise", personality = "Personality"
        case coreValues = "Core Values", constraints = "Constraints"
    }

    static let listFields: [Field] = [.expertise, .personality, .coreValues, .constraints]

    struct Failure: Error, Equatable {
        let field: Field
        let reason: MarkdownPatch.Failure
    }

    static func parse(_ raw: String) -> SoulData {
        var data = SoulData()
        for section in MarkdownPatch.sections(raw) where section.level == 2 {
            switch section.heading.flatMap(Field.init(rawValue:)) {
            case .name: data.name = managedLine(section.raw).map { MarkdownPatch.stripEol($0.line).trimmingCharacters(in: .whitespaces) } ?? ""
            case .expertise: data.expertise = MarkdownPatch.managedBullets(section.raw)
            case .personality: data.personality = MarkdownPatch.managedBullets(section.raw)
            case .coreValues: data.coreValues = MarkdownPatch.managedBullets(section.raw)
            case .constraints: data.constraints = MarkdownPatch.managedBullets(section.raw)
            case nil: break
            }
        }
        return data
    }

    static func patch(_ raw: String, to next: SoulData) -> Result<String, Failure> {
        let previous = parse(raw)
        var current = raw
        if previous.name != next.name {
            switch patchName(current, next.name) {
            case let .success(updated): current = updated
            case let .failure(reason): return .failure(Failure(field: .name, reason: reason))
            }
        }
        for field in listFields where list(previous, field) != list(next, field) {
            let result = MarkdownPatch.patchListSection(current, level: 2, heading: field.rawValue,
                                                        old: list(previous, field), new: list(next, field))
            switch result {
            case let .success(updated): current = updated
            case let .failure(reason): return .failure(Failure(field: field, reason: reason))
            }
        }
        return .success(current)
    }

    /// Fields the form cannot save in this file (probed with a dummy edit).
    static func blocked(_ raw: String) -> [Failure] {
        Field.allCases.compactMap { field in
            var probe = parse(raw)
            switch field {
            case .name: probe.name += "probe"
            case .expertise: probe.expertise.append("probe")
            case .personality: probe.personality.append("probe")
            case .coreValues: probe.coreValues.append("probe")
            case .constraints: probe.constraints.append("probe")
            }
            if case let .failure(failure) = patch(raw, to: probe) { return failure }
            return nil
        }
    }

    static func merge(base: SoulData, mine: SoulData, theirs: SoulData) -> SoulData? {
        guard let name = StructuredEditing.pick(base.name, mine.name, theirs.name),
              let expertise = StructuredEditing.pick(base.expertise, mine.expertise, theirs.expertise),
              let personality = StructuredEditing.pick(base.personality, mine.personality, theirs.personality),
              let coreValues = StructuredEditing.pick(base.coreValues, mine.coreValues, theirs.coreValues),
              let constraints = StructuredEditing.pick(base.constraints, mine.constraints, theirs.constraints) else { return nil }
        return SoulData(name: name, expertise: expertise, personality: personality, coreValues: coreValues, constraints: constraints)
    }

    static func list(_ data: SoulData, _ field: Field) -> [String] {
        switch field {
        case .name: [data.name]
        case .expertise: data.expertise
        case .personality: data.personality
        case .coreValues: data.coreValues
        case .constraints: data.constraints
        }
    }

    /// First non-blank, non-comment line after the heading, outside fences.
    private static func managedLine(_ sectionRaw: String) -> (index: Int, line: String)? {
        var fence = MarkdownPatch.Fence()
        for (index, line) in MarkdownPatch.splitLines(sectionRaw).enumerated().dropFirst() {
            let content = MarkdownPatch.stripEol(line)
            if fence.consume(content) || fence.inside { continue }
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("<!--") { continue }
            return (index, line)
        }
        return nil
    }

    private static func patchName(_ raw: String, _ name: String) -> Result<String, MarkdownPatch.Failure> {
        let all = MarkdownPatch.sections(raw)
        let index: Int
        switch MarkdownPatch.uniqueSection(all, level: 2, heading: Field.name.rawValue) {
        case let .success(found): index = found
        case let .failure(failure): return .failure(failure)
        }
        var lines = MarkdownPatch.splitLines(all[index].raw)
        if let managed = managedLine(all[index].raw) {
            if name.isEmpty {
                lines.remove(at: managed.index)
            } else {
                lines[managed.index] = name + MarkdownPatch.lineEol(managed.line)
            }
        } else {
            guard !name.isEmpty else { return .success(raw) }
            let eol = MarkdownPatch.detectEol(raw)
            lines = [MarkdownPatch.headingLine(lines, eol), name + eol] + Array(lines.dropFirst())
        }
        return .success(MarkdownPatch.replacing(all, at: index, lines: lines))
    }
}
