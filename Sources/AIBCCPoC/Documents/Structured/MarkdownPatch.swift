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

    enum Failure: Error, Equatable { case sectionNotFound, multipleSections, noBulletRun, multipleBulletRuns }

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
