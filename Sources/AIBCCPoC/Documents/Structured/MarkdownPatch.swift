import Foundation

/// Port of CC v1.6.1 `documentPatch.ts`: byte-preserving Markdown editing.
/// Lines keep their own endings ("\n" or "\r\n"); work is done on Unicode
/// scalars because Swift treats "\r\n" as one Character, so `hasSuffix("\n")`
/// would miss a CRLF line.
enum MarkdownPatch {
    struct Section: Equatable {
        let level: Int
        let heading: String?
        let raw: String
    }

    enum Failure: Error, Equatable {
        case sectionNotFound, multipleSections, noBulletRun, multipleBulletRuns
        /// Bullets at different indents (a nested list): rewriting the run
        /// with one style would flatten it (r5).
        case nestedBullets
    }

    static func detectEol(_ raw: String) -> String {
        var crlf = 0
        var lf = 0
        var previous: Unicode.Scalar?
        for scalar in raw.unicodeScalars {
            if scalar == "\n" { previous == "\r" ? (crlf += 1) : (lf += 1) }
            previous = scalar
        }
        return crlf > lf ? "\r\n" : "\n"
    }

    static func splitLines(_ raw: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            current.append(scalar)
            if scalar == "\n" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { lines.append(String(current)) }
        return lines
    }

    static func stripEol(_ line: String) -> String {
        var scalars = Array(line.unicodeScalars)
        if scalars.last == "\n" { scalars.removeLast() }
        if scalars.last == "\r", line.unicodeScalars.last == "\n" { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    static func lineEol(_ line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        guard scalars.last == "\n" else { return "" }
        return scalars.count >= 2 && scalars[scalars.count - 2] == "\r" ? "\r\n" : "\n"
    }

    /// Splits at ATX headings outside fenced code; the first section is
    /// the preamble (level 0). Joining the raws gives the input back.
    static func sections(_ raw: String) -> [Section] {
        var result: [Section] = []
        var level = 0
        var heading: String?
        var buffer: [String] = []
        var fence = Fence()
        for line in splitLines(raw) {
            let content = stripEol(line)
            fence.consume(content)
            if !fence.inside, let match = Regex.capture(#"^(#{1,6})[ \t]+(.+?)(?:[ \t]+#+)?[ \t]*$"#, content) {
                result.append(Section(level: level, heading: heading, raw: buffer.joined()))
                level = match[1].count
                heading = match[2].trimmingCharacters(in: .whitespaces)
                buffer = [line]
            } else {
                buffer.append(line)
            }
        }
        result.append(Section(level: level, heading: heading, raw: buffer.joined()))
        return result
    }

    static func isBullet(_ content: String) -> Bool {
        Regex.matches(#"^[ \t]*[-*+][ \t]+"#, content)
    }

    /// Runs of consecutive bullet lines outside fenced code, from `start`.
    static func bulletRuns(_ lines: [String], from start: Int) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var fence = Fence()
        var index = start
        while index < lines.count {
            let content = stripEol(lines[index])
            if fence.consume(content) || fence.inside {
                index += 1
                continue
            }
            if isBullet(content) {
                var end = index + 1
                while end < lines.count, isBullet(stripEol(lines[end])) { end += 1 }
                runs.append(index..<end)
                index = end
            } else {
                index += 1
            }
        }
        return runs
    }

    /// Replaces the single bullet run of the section `level`/`heading`,
    /// keeping its indent, marker, line endings and everything around it.
    static func patchBulletRun(_ raw: String, level: Int, heading: String, bullets: [String]) -> Result<String, Failure> {
        let all = sections(raw)
        let matching = all.indices.filter { all[$0].level == level && all[$0].heading == heading }
        guard let index = matching.first else { return .failure(.sectionNotFound) }
        guard matching.count == 1 else { return .failure(.multipleSections) }
        let lines = splitLines(all[index].raw)
        let runs = bulletRuns(lines, from: all[index].level > 0 ? 1 : 0)
        guard let run = runs.first else { return .failure(.noBulletRun) }
        guard runs.count == 1 else { return .failure(.multipleBulletRuns) }
        guard let style = Regex.capture(#"^([ \t]*)([-*+][ \t]+)"#, stripEol(lines[run.lowerBound])) else {
            return .failure(.noBulletRun)
        }
        let indents = Set(lines[run].map { stripEol($0).prefix { $0 == " " || $0 == "\t" } })
        guard indents.count == 1, !hasHangingContent(lines, after: run) else { return .failure(.nestedBullets) }
        let eol = lines[run].map(lineEol).first { !$0.isEmpty } ?? detectEol(raw)
        let lastHadEol = !lineEol(lines[run.upperBound - 1]).isEmpty
        let replacement = bullets.enumerated().map { offset, bullet in
            style[1] + style[2] + bullet + (offset == bullets.count - 1 && !lastHadEol ? "" : eol)
        }
        let patched = Array(lines[..<run.lowerBound]) + replacement + Array(lines[run.upperBound...])
        var updated = all
        updated[index] = Section(level: all[index].level, heading: all[index].heading, raw: patched.joined())
        return .success(updated.map(\.raw).joined())
    }

    /// Lines after a bullet run that still belong to its last item, which a
    /// rewrite of the run would hand to another item: a line straight after
    /// it (a lazy continuation, unless a heading), or indented content after
    /// blank lines — an ordered sub-list, a second paragraph (Codex r6).
    static func hasHangingContent(_ lines: [String], after run: Range<Int>) -> Bool {
        var index = run.upperBound
        if index < lines.count {
            let content = stripEol(lines[index])
            // Only a real ATX heading ends the item: `#tag` or seven hashes
            // are its text (r7).
            if !content.trimmingCharacters(in: .whitespaces).isEmpty, !isHeading(content) { return true }
        }
        while index < lines.count, stripEol(lines[index]).trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
        guard index < lines.count else { return false }
        return stripEol(lines[index]).first.map { $0 == " " || $0 == "\t" } ?? false
    }

    /// A CommonMark ATX heading line: up to 3 spaces, 1–6 `#`, then a space
    /// or the end of the line.
    static func isHeading(_ content: String) -> Bool {
        Regex.matches(#"^ {0,3}#{1,6}([ \t]|$)"#, content)
    }

    /// Bullet texts of a section, skipping fenced code (v1 extractManagedBullets).
    static func managedBullets(_ sectionRaw: String) -> [String] {
        var fence = Fence()
        return splitLines(sectionRaw).dropFirst().compactMap { line in
            let content = stripEol(line)
            if fence.consume(content) || fence.inside { return nil }
            return Regex.capture(#"^[ \t]*[-*+][ \t]+(.*)$"#, content)?[1]
        }
    }

    /// The one section `level`/`heading`, or why it cannot be edited.
    static func uniqueSection(_ all: [Section], level: Int, heading: String) -> Result<Int, Failure> {
        let matching = all.indices.filter { all[$0].level == level && all[$0].heading == heading }
        guard let index = matching.first else { return .failure(.sectionNotFound) }
        return matching.count == 1 ? .success(index) : .failure(.multipleSections)
    }

    /// v1 rules/soul `patchListSection`: replace the section's single bullet
    /// run, or fill a section that had no bullets. A run that cannot be
    /// located unambiguously is reported as `multipleBulletRuns`.
    static func patchListSection(_ raw: String, level: Int, heading: String, old: [String], new: [String]) -> Result<String, Failure> {
        let all = sections(raw)
        let index: Int
        switch uniqueSection(all, level: level, heading: heading) {
        case let .success(found): index = found
        case let .failure(failure): return .failure(failure)
        }
        let lines = splitLines(all[index].raw)
        let runs = bulletRuns(lines, from: 1)
        guard runs.count <= 1 else { return .failure(.multipleBulletRuns) }
        if runs.count == 1 {
            return patchBulletRun(raw, level: level, heading: heading, bullets: new)
                .mapError { $0 == .noBulletRun ? .multipleBulletRuns : $0 }
        }
        // No run: only fill a section that was empty.
        guard old.isEmpty else { return .failure(.multipleBulletRuns) }
        guard !new.isEmpty else { return .success(raw) }
        let eol = detectEol(raw)
        return .success(replacing(all, at: index, lines: [headingLine(lines, eol)] + new.map { "- \($0)\(eol)" } + Array(lines.dropFirst())))
    }

    /// The section's heading line, given an ending if it had none.
    static func headingLine(_ lines: [String], _ eol: String) -> String {
        let heading = lines.first ?? ""
        return lineEol(heading).isEmpty ? heading + eol : heading
    }

    /// The document with section `index` rebuilt from `lines`.
    static func replacing(_ all: [Section], at index: Int, lines: [String]) -> String {
        var updated = all
        updated[index] = Section(level: all[index].level, heading: all[index].heading, raw: lines.joined())
        return updated.map(\.raw).joined()
    }

    /// Fenced-code tracking (``` or ~~~, closed by the same char, ≥ length).
    struct Fence {
        private var char: Character?
        private var length = 0
        var inside: Bool { char != nil }

        /// True when `content` is a fence line (opening or closing).
        @discardableResult
        mutating func consume(_ content: String) -> Bool {
            guard let marker = Regex.capture(#"^ {0,3}(`{3,}|~{3,})"#, content)?[1], let first = marker.first else { return false }
            if char == nil {
                char = first
                length = marker.count
            } else if first == char, marker.count >= length {
                char = nil
                length = 0
            }
            return true
        }
    }
}

/// Small NSRegularExpression helpers (patterns are constants).
enum Regex {
    static func capture(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        capture(pattern, text) != nil
    }
}
