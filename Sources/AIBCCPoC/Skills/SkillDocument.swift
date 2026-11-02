import Foundation

/// The fields of a SKILL.md the form edits (aib skills protocol): `name`
/// is always the slug, so it is not a field here.
struct SkillFields: Equatable {
    var description = ""
    var argumentHint = ""
    var allowedTools = ""
}

/// SKILL.md = `---` frontmatter `---` + body. Edits patch single frontmatter
/// lines (comments, key order, quoting and unknown keys such as aib_version
/// or upstream stay byte-identical) — v1 re-serialized the whole block.
/// aib reads frontmatter one line per key (awk), so values stay on one line
/// and block scalars (`description: >`) are not editable as a form.
enum SkillDocument {
    enum Key: String, CaseIterable {
        case name, description, argumentHint = "argument-hint", allowedTools = "allowed-tools"
    }

    enum Failure: Error, Equatable {
        case noFrontmatter, duplicateKey(String), multilineValue(String)
    }

    /// Minimum description length (v1 form rule): the description is the
    /// discovery trigger agents match against.
    static let minimumDescription = 20

    struct Parts {
        /// Opening fence through closing fence.
        let head: [String]
        /// The blank line between the closing fence and the body, if any.
        let gap: String
        let body: String
    }

    static func validate(slug: String) -> String? {
        if slug.isEmpty { return "slug가 비었습니다" }
        guard Regex.matches(#"^[a-z][a-z0-9-]*$"#, slug) else { return "slug는 영소문자로 시작하고 영소문자·숫자·-만 씁니다" }
        return nil
    }

    static func split(_ raw: String) -> Parts? {
        let lines = MarkdownPatch.splitLines(raw)
        let isFence = { (line: String) in Regex.matches(#"^---\s*$"#, MarkdownPatch.stripEol(line)) }
        guard let first = lines.first, isFence(first),
              let close = lines.indices.dropFirst().first(where: { isFence(lines[$0]) }) else { return nil }
        var rest = Array(lines[(close + 1)...])
        var gap = ""
        if let next = rest.first, MarkdownPatch.stripEol(next).trimmingCharacters(in: .whitespaces).isEmpty {
            gap = next
            rest.removeFirst()
        }
        return Parts(head: Array(lines[...close]), gap: gap, body: rest.joined())
    }

    static func fields(_ raw: String) -> SkillFields {
        guard let parts = split(raw) else { return SkillFields() }
        let get = { (key: Key) in value(parts.head, key) ?? "" }
        return SkillFields(description: get(.description), argumentHint: get(.argumentHint), allowedTools: get(.allowedTools))
    }

    static func name(_ raw: String) -> String? {
        split(raw).flatMap { value($0.head, .name) }
    }

    /// Keys whose current value cannot round-trip through a one-line field.
    static func multilineKeys(_ raw: String) -> [Key] {
        guard let parts = split(raw) else { return [] }
        return Key.allCases.filter { key in
            guard let index = keyLines(parts.head, key).first else { return false }
            return isMultiline(parts.head, at: index)
        }
    }

    /// A new SKILL.md in the shape of the existing ones.
    static func render(slug: String, fields: SkillFields, body: String) -> String {
        var lines = ["---", "name: \(slug)", "description: \(YamlScalar.doubleQuoted(fields.description))"]
        if !fields.argumentHint.isEmpty { lines.append("argument-hint: \(YamlScalar.doubleQuoted(fields.argumentHint))") }
        if !fields.allowedTools.isEmpty { lines.append("allowed-tools: \(YamlScalar.render(like: "", fields.allowedTools))") }
        lines += ["aib_version: \"1.1\"", "growth_origin: \"manual\"", "---", "", body]
        let text = lines.joined(separator: "\n")
        return text.hasSuffix("\n") ? text : text + "\n"
    }

    /// The file with `fields` and `body` applied; untouched lines keep their bytes.
    static func patch(_ raw: String, fields: SkillFields, body: String) -> Result<String, Failure> {
        guard let parts = split(raw) else { return .failure(.noFrontmatter) }
        var head = parts.head
        let current = SkillDocument.fields(raw)
        let changes: [(Key, String, String)] = [(.description, current.description, fields.description),
                                                (.argumentHint, current.argumentHint, fields.argumentHint),
                                                (.allowedTools, current.allowedTools, fields.allowedTools)]
        for (key, old, new) in changes where old != new {
            switch set(head, key, new, required: key == .description) {
            case let .success(updated): head = updated
            case let .failure(failure): return .failure(failure)
            }
        }
        guard body != parts.body else { return .success(head.joined() + parts.gap + parts.body) }
        let eol = MarkdownPatch.detectEol(raw)
        // A closing fence at the very end of the file has no line ending.
        if let last = head.indices.last, MarkdownPatch.lineEol(head[last]).isEmpty, !body.isEmpty { head[last] += eol }
        let newBody = body.isEmpty || body.hasSuffix("\n") ? body : body + eol
        return .success(head.joined() + parts.gap + newBody)
    }

    /// The file with `name:` set to `slug` (after a rename).
    static func renamed(_ raw: String, to slug: String) -> Result<String, Failure> {
        guard let parts = split(raw) else { return .failure(.noFrontmatter) }
        return set(parts.head, .name, slug, required: true).map { $0.joined() + parts.gap + parts.body }
    }

    // MARK: - Frontmatter lines

    private static func keyLines(_ head: [String], _ key: Key) -> [Int] {
        head.indices.dropFirst().dropLast().filter { Regex.matches("^\(key.rawValue)\\s*:", MarkdownPatch.stripEol(head[$0])) }
    }

    private static func value(_ head: [String], _ key: Key) -> String? {
        keyLines(head, key).first.map { YamlScalar.unquote(YamlScalar.valuePart(MarkdownPatch.stripEol(head[$0]))) }
    }

    /// A block scalar (`|`, `>`) or a value continued on indented lines.
    private static func isMultiline(_ head: [String], at index: Int) -> Bool {
        let value = YamlScalar.valuePart(MarkdownPatch.stripEol(head[index]))
        if Regex.matches(#"^[|>][-+0-9]*$"#, value) { return true }
        let next = index + 1
        return next < head.count - 1 && Regex.matches(#"^\s+\S"#, MarkdownPatch.stripEol(head[next]))
    }

    private static func set(_ head: [String], _ key: Key, _ value: String, required: Bool) -> Result<[String], Failure> {
        var lines = head
        let matches = keyLines(lines, key)
        guard matches.count <= 1 else { return .failure(.duplicateKey(key.rawValue)) }
        let eol = MarkdownPatch.lineEol(lines[0]).isEmpty ? "\n" : MarkdownPatch.lineEol(lines[0])
        guard let index = matches.first else {
            guard !value.isEmpty else { return .success(lines) }
            lines.insert("\(key.rawValue): \(YamlScalar.render(like: "", value))\(eol)", at: lines.count - 1)
            return .success(lines)
        }
        guard !isMultiline(lines, at: index) else { return .failure(.multilineValue(key.rawValue)) }
        if value.isEmpty, !required {
            lines.remove(at: index)
        } else {
            lines[index] = YamlScalar.renderLine(MarkdownPatch.stripEol(lines[index]), value) + MarkdownPatch.lineEol(lines[index])
        }
        return .success(lines)
    }
}
