import Foundation

/// Port of CC v1.6.1 `yamlDocument.ts`: the agent.yaml fields the form
/// edits (name, version, description, models.primary, models.fallback,
/// aib_version), patched line by line so comments, quoting style and every
/// other block (memory, hooks, skills, constitution, …) stay byte-identical.
///
/// Deliberate differences from v1, each a case where v1 wrote broken or
/// misleading YAML: a fallback inserted after a last line without a newline
/// gets one; `fallback: []` becomes a block list (v1 appended items after
/// the `[]`); a non-empty flow list or a fallback list interrupted by a
/// comment/blank line fails closed; values starting with a YAML indicator
/// character are quoted.
struct AgentConfig: Equatable {
    var name = ""
    var version = ""
    var description = ""
    var primaryModel = ""
    var fallbackModels: [String] = []
    var aibVersion = ""
}

enum AgentYamlDocument {
    enum Field: String, CaseIterable {
        case name, version, description, primaryModel = "models.primary", fallbackModels = "models.fallback", aibVersion = "aib_version"
    }

    enum Reason: Error, Equatable {
        case keyNotFound, multipleKeys, modelsNotFound, primaryNotFound, fallbackNotBlockList, fallbackNotContiguous
        /// A block scalar (`|`, `>`) or a value continued on indented lines:
        /// a one-line edit would leave the rest as broken YAML (r5).
        case multilineValue
    }

    struct Failure: Error, Equatable {
        let field: Field
        let reason: Reason
    }

    private static let scalarKeys: [(Field, String)] = [(.name, "name"), (.version, "version"), (.description, "description"),
                                                         (.aibVersion, "aib_version")]

    static func parse(_ raw: String) -> AgentConfig {
        var config = AgentConfig()
        var inModels = false
        var inFallback = false
        for line in MarkdownPatch.splitLines(raw) {
            let content = MarkdownPatch.stripEol(line)
            if Regex.matches(#"^models\s*:"#, content) {
                inModels = true
                inFallback = false
            } else if let key = scalarKeys.first(where: { content.hasPrefix($0.1 + ":") }) {
                let value = YamlScalar.unquote(YamlScalar.valuePart(content))
                switch key.0 {
                case .name: config.name = value
                case .version: config.version = value
                case .description: config.description = value
                default: config.aibVersion = value
                }
                inModels = false
                inFallback = false
            } else if isTopLevelKey(content) {
                inModels = false
                inFallback = false
            } else if inModels, Regex.matches(#"^\s+primary:"#, content) {
                config.primaryModel = YamlScalar.unquote(YamlScalar.valuePart(content))
                inFallback = false
            } else if inModels, Regex.matches(#"^\s+fallback:\s*(?:#.*)?$"#, content) {
                inFallback = true
            } else if inModels, inFallback, Regex.matches(#"^\s+-\s+"#, content) {
                config.fallbackModels.append(YamlScalar.unquote(YamlScalar.listValuePart(content)))
            } else if inModels, inFallback, Regex.matches(#"^\s+\S"#, content) {
                inFallback = false
            }
        }
        return config
    }

    static func patch(_ raw: String, to next: AgentConfig) -> Result<String, Failure> {
        let previous = parse(raw)
        var current = raw
        for (field, key) in scalarKeys where value(previous, field) != value(next, field) {
            switch patchScalar(current, key: key, value: value(next, field)) {
            case let .success(updated): current = updated
            case let .failure(reason): return .failure(Failure(field: field, reason: reason))
            }
        }
        if previous.primaryModel != next.primaryModel {
            switch patchPrimary(current, next.primaryModel) {
            case let .success(updated): current = updated
            case let .failure(reason): return .failure(Failure(field: .primaryModel, reason: reason))
            }
        }
        if previous.fallbackModels != next.fallbackModels {
            switch patchFallback(current, next.fallbackModels) {
            case let .success(updated): current = updated
            case let .failure(reason): return .failure(Failure(field: .fallbackModels, reason: reason))
            }
        }
        return .success(current)
    }

    /// Editable fields the form cannot save in this file (probed).
    static func blocked(_ raw: String) -> [Failure] {
        Field.allCases.filter { $0 != .aibVersion }.compactMap { field in
            var probe = parse(raw)
            switch field {
            case .name: probe.name += "probe"
            case .version: probe.version += "probe"
            case .description: probe.description += "probe"
            case .primaryModel: probe.primaryModel += "probe"
            case .fallbackModels: probe.fallbackModels.append("probe")
            case .aibVersion: break
            }
            if case let .failure(failure) = patch(raw, to: probe) { return failure }
            return nil
        }
    }

    static func merge(base: AgentConfig, mine: AgentConfig, theirs: AgentConfig) -> AgentConfig? {
        guard let name = StructuredEditing.pick(base.name, mine.name, theirs.name),
              let version = StructuredEditing.pick(base.version, mine.version, theirs.version),
              let description = StructuredEditing.pick(base.description, mine.description, theirs.description),
              let primary = StructuredEditing.pick(base.primaryModel, mine.primaryModel, theirs.primaryModel),
              let fallback = StructuredEditing.pick(base.fallbackModels, mine.fallbackModels, theirs.fallbackModels),
              let aib = StructuredEditing.pick(base.aibVersion, mine.aibVersion, theirs.aibVersion) else { return nil }
        return AgentConfig(name: name, version: version, description: description, primaryModel: primary,
                           fallbackModels: fallback, aibVersion: aib)
    }

    /// Top-level keys the form does not edit (shown as preserved).
    static func otherKeys(_ raw: String) -> [String] {
        let known = Set(scalarKeys.map(\.1) + ["models"])
        return MarkdownPatch.splitLines(raw).compactMap { line in
            Regex.capture(#"^([A-Za-z_][A-Za-z0-9_-]*)\s*:"#, MarkdownPatch.stripEol(line))?[1]
        }.filter { !known.contains($0) }
    }

    private static func value(_ config: AgentConfig, _ field: Field) -> String {
        switch field {
        case .name: config.name
        case .version: config.version
        case .description: config.description
        case .aibVersion: config.aibVersion
        case .primaryModel: config.primaryModel
        case .fallbackModels: config.fallbackModels.joined(separator: "\n")
        }
    }

    private static func isTopLevelKey(_ line: String) -> Bool {
        Regex.matches(#"^[A-Za-z_][A-Za-z0-9_-]*\s*:"#, line)
    }

    private static func patchScalar(_ raw: String, key: String, value: String) -> Result<String, Reason> {
        var lines = MarkdownPatch.splitLines(raw)
        let matches = lines.indices.filter { Regex.matches("^\(key)\\s*:", MarkdownPatch.stripEol(lines[$0])) }
        guard let index = matches.first else { return .failure(.keyNotFound) }
        guard matches.count == 1 else { return .failure(.multipleKeys) }
        guard !YamlScalar.isMultiline(lines, at: index) else { return .failure(.multilineValue) }
        lines[index] = YamlScalar.renderLine(MarkdownPatch.stripEol(lines[index]), value) + MarkdownPatch.lineEol(lines[index])
        return .success(lines.joined())
    }

    /// The single `models:` block: its line and the end (next top-level key).
    private static func modelsBlock(_ lines: [String]) -> (start: Int, end: Int)? {
        let starts = lines.indices.filter { Regex.matches(#"^models\s*:"#, MarkdownPatch.stripEol(lines[$0])) }
        guard starts.count == 1, let start = starts.first else { return nil }
        let end = (start + 1..<lines.count).first { isTopLevelKey(MarkdownPatch.stripEol(lines[$0])) } ?? lines.count
        return (start, end)
    }

    private static func patchPrimary(_ raw: String, _ value: String) -> Result<String, Reason> {
        var lines = MarkdownPatch.splitLines(raw)
        guard let block = modelsBlock(lines) else { return .failure(.modelsNotFound) }
        guard let index = (block.start + 1..<block.end).first(where: { Regex.matches(#"^\s+primary\s*:"#, MarkdownPatch.stripEol(lines[$0])) }) else {
            return .failure(.primaryNotFound)
        }
        guard !YamlScalar.isMultiline(lines, at: index) else { return .failure(.multilineValue) }
        lines[index] = YamlScalar.renderLine(MarkdownPatch.stripEol(lines[index]), value) + MarkdownPatch.lineEol(lines[index])
        return .success(lines.joined())
    }

    private static func patchFallback(_ raw: String, _ values: [String]) -> Result<String, Reason> {
        var lines = MarkdownPatch.splitLines(raw)
        guard let block = modelsBlock(lines) else { return .failure(.modelsNotFound) }
        let eol = MarkdownPatch.detectEol(raw)
        let content = { (index: Int) in MarkdownPatch.stripEol(lines[index]) }
        let isItem = { (index: Int) in Regex.matches(#"^\s+-\s+"#, content(index)) }
        guard let fallback = (block.start + 1..<block.end).first(where: { Regex.matches(#"^\s+fallback\s*:"#, content($0)) }) else {
            guard !values.isEmpty else { return .success(raw) }
            let primary = (block.start + 1..<block.end).last { Regex.matches(#"^\s+primary\s*:"#, content($0)) }
            let insertAt = primary.map { $0 + 1 } ?? block.start + 1
            if MarkdownPatch.lineEol(lines[insertAt - 1]).isEmpty { lines[insertAt - 1] += eol }
            let added = ["  fallback:\(eol)"] + values.map { "    - \(YamlScalar.render(like: "", $0))\(eol)" }
            lines.insert(contentsOf: added, at: insertAt)
            return .success(lines.joined())
        }
        // An empty flow list (`fallback: []`, the aib template) becomes a
        // block list; any other flow list cannot be edited line by line.
        var header = content(fallback)
        if let flow = Regex.capture(#"^(\s+fallback\s*:)\s*\[\s*\](\s*#.*)?$"#, header) {
            header = flow[1] + flow[2]
        } else if !Regex.matches(#"^\s+fallback\s*:\s*(?:#.*)?$"#, header) {
            return .failure(.fallbackNotBlockList)
        }
        let listStart = fallback + 1
        var listEnd = listStart
        while listEnd < block.end, isItem(listEnd) { listEnd += 1 }
        // More items after a comment or blank line: the list the form shows
        // is not the whole list.
        for index in listEnd..<block.end {
            let trimmed = content(index).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if isItem(index) { return .failure(.fallbackNotContiguous) }
            break
        }
        if values.isEmpty {
            lines.removeSubrange(fallback..<listEnd)
            return .success(lines.joined())
        }
        let fallbackEol = MarkdownPatch.lineEol(lines[fallback]).isEmpty ? eol : MarkdownPatch.lineEol(lines[fallback])
        let hasItems = listStart < listEnd
        let indent = hasItems ? (Regex.capture(#"^(\s*)"#, content(listStart))?[1] ?? "    ") : "    "
        let itemEol = hasItems && !MarkdownPatch.lineEol(lines[listStart]).isEmpty ? MarkdownPatch.lineEol(lines[listStart]) : fallbackEol
        let items = values.enumerated().map { offset, value -> String in
            guard offset < listEnd - listStart else { return "\(indent)- \(YamlScalar.render(like: "", value))\(itemEol)" }
            let old = lines[listStart + offset]
            let ending = MarkdownPatch.lineEol(old).isEmpty ? itemEol : MarkdownPatch.lineEol(old)
            return YamlScalar.renderItem(MarkdownPatch.stripEol(old), value) + ending
        }
        lines.replaceSubrange(fallback..<listEnd, with: [header + fallbackEol] + items)
        return .success(lines.joined())
    }
}

/// YAML scalar text as v1 handles it: a value, an optional trailing
/// `# comment` (outside quotes), and the quoting style to keep.
enum YamlScalar {
    static func splitValueAndComment(_ rest: String) -> (value: String, comment: String) {
        let chars = Array(rest)
        var quote: Character?
        for index in chars.indices {
            let char = chars[index]
            if let open = quote {
                if char == open, index == 0 || chars[index - 1] != "\\" { quote = nil }
                continue
            }
            if char == "\"" || char == "'" {
                quote = char
                continue
            }
            if char == "#", index == 0 || chars[index - 1].isWhitespace {
                let value = String(chars[..<index]).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
                return (value, String(chars[(index == 0 ? index : index - 1)...]))
            }
        }
        return (rest, "")
    }

    static func valuePart(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return splitValueAndComment(String(line[line.index(after: colon)...])).value.trimmingCharacters(in: .whitespaces)
    }

    static func listValuePart(_ line: String) -> String {
        let item = line.replacingOccurrences(of: #"^\s+-\s+"#, with: "", options: .regularExpression)
        return splitValueAndComment(item).value.trimmingCharacters(in: .whitespaces)
    }

    /// `key: value # comment` with the value replaced in the old style.
    static func renderLine(_ old: String, _ value: String) -> String {
        guard let colon = old.firstIndex(of: ":") else { return old }
        let prefix = String(old[...colon])
        let parts = splitValueAndComment(String(old[old.index(after: colon)...]))
        return "\(prefix) \(render(like: parts.value.trimmingCharacters(in: .whitespaces), value))\(parts.comment)"
    }

    static func renderItem(_ old: String, _ value: String) -> String {
        guard let match = Regex.capture(#"^(\s*-\s*)(.*)$"#, old) else { return "    - \(render(like: "", value))" }
        let parts = splitValueAndComment(match[2])
        return "\(match[1])\(render(like: parts.value.trimmingCharacters(in: .whitespaces), value))\(parts.comment)"
    }

    static func render(like old: String, _ value: String) -> String {
        if old.count >= 2, old.hasPrefix("'"), old.hasSuffix("'") { return "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        if old.count >= 2, old.hasPrefix("\""), old.hasSuffix("\"") { return doubleQuoted(value) }
        return needsQuotes(value) ? doubleQuoted(value) : value
    }

    /// Plain-scalar safety: quote whatever YAML would parse differently or
    /// reject — a key-like colon (also at the end), comments, indicators, and
    /// values that resolve to null, booleans or numbers (YAML 1.1 and 1.2).
    static func needsQuotes(_ value: String) -> Bool {
        value.isEmpty || value.trimmingCharacters(in: .whitespaces) != value || value.contains("#")
            || Regex.matches(#":(\s|$)"#, value) || value.contains("\n") || value.contains("\r") || value.contains("\t")
            || value.first.map { "-?:,[]{}&*!|>'\"%@`".contains($0) } == true
            || resolvesToNonString(value)
    }

    static func resolvesToNonString(_ value: String) -> Bool {
        let special: Set = ["null", "~", "true", "false", "yes", "no", "on", "off", "y", "n", ".inf", "-.inf", "+.inf", ".nan"]
        return special.contains(value.lowercased())
            || Regex.matches(#"^[-+]?(\.[0-9]+|[0-9][0-9_]*(\.[0-9_]*)?)([eE][-+]?[0-9]+)?$"#, value)
            || Regex.matches(#"^0x[0-9a-fA-F_]+$|^0o?[0-7_]+$|^0b[01_]+$"#, value)
            || Regex.matches(#"^[0-9]{4}-[0-9]{2}-[0-9]{2}"#, value)
    }

    /// The value on line `index` is a block scalar or continues on deeper
    /// indented lines (blank lines and comments in between allowed).
    static func isMultiline(_ lines: [String], at index: Int) -> Bool {
        let line = MarkdownPatch.stripEol(lines[index])
        if Regex.matches(#"^[|>][-+0-9]*$"#, valuePart(line)) || continuesOnNextLine(valuePart(line)) { return true }
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        for next in lines[(index + 1)...] {
            let content = MarkdownPatch.stripEol(next)
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            return content.prefix { $0 == " " || $0 == "\t" }.count > indent
        }
        return false
    }

    /// A quoted scalar or flow collection that does not close on its own
    /// line goes on at any indentation, the same one included (Codex r6: a
    /// `"first` / `second"` pair at one indent passed the indent check).
    static func continuesOnNextLine(_ value: String) -> Bool {
        let chars = Array(value.trimmingCharacters(in: .whitespaces))
        guard let first = chars.first else { return false }
        var index = 1
        switch first {
        case "\"":
            while index < chars.count {
                if chars[index] == "\\" { index += 2; continue }
                if chars[index] == "\"" { return false }
                index += 1
            }
            return true
        case "'":
            while index < chars.count {
                if chars[index] == "'" {
                    if index + 1 < chars.count, chars[index + 1] == "'" { index += 2; continue }
                    return false
                }
                index += 1
            }
            return true
        case "[", "{":
            var depth = 0
            var quote: Character?
            index = 0
            while index < chars.count {
                let char = chars[index]
                if let open = quote {
                    if open == "\"", char == "\\" { index += 2; continue }
                    if char == open { quote = nil }
                } else if char == "\"" || char == "'" {
                    quote = char
                } else if char == "[" || char == "{" {
                    depth += 1
                } else if char == "]" || char == "}" {
                    depth -= 1
                } else if char == "#", index > 0, chars[index - 1] == " " {
                    break
                }
                index += 1
            }
            return quote != nil || depth > 0
        default:
            return false
        }
    }

    static func doubleQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            var result = ""
            var escaping = false
            for char in trimmed.dropFirst().dropLast() {
                if escaping {
                    switch char {
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "\\", "\"": result.append(char)
                    default: result.append("\\"); result.append(char)
                    }
                    escaping = false
                } else if char == "\\" {
                    escaping = true
                } else {
                    result.append(char)
                }
            }
            return escaping ? result + "\\" : result
        }
        if trimmed.count >= 2, trimmed.hasPrefix("'"), trimmed.hasSuffix("'") {
            return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return trimmed
    }
}
