import Foundation

/// What the renderer gets. The renderer escapes raw HTML (MD-05), so the
/// metadata comments aib keeps in its files (`<!-- AIB:OWNERSHIP … -->`,
/// section hints) would show up as literal text; the ownership seal
/// already says what they say. Comments inside fenced code stay.
enum MarkdownSource {
    static func forDisplay(_ source: String) -> String {
        var output: [Substring] = []
        var inFence = false
        var inComment = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if !inComment, line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                output.append(line)
                continue
            }
            if inFence {
                output.append(line)
                continue
            }
            let (kept, stillOpen) = stripComments(line, open: inComment)
            inComment = stillOpen
            // A line that held only a comment disappears instead of leaving a gap.
            if kept.trimmingCharacters(in: .whitespaces).isEmpty && kept.count != line.count { continue }
            output.append(Substring(kept))
        }
        return output.joined(separator: "\n")
    }

    /// Removes `<!-- … -->` spans from one line; `open` carries a comment
    /// that started on an earlier line.
    private static func stripComments(_ line: Substring, open: Bool) -> (String, Bool) {
        var result = ""
        var rest = line[...]
        var inside = open
        while !rest.isEmpty {
            if inside {
                guard let end = rest.range(of: "-->") else { return (result, true) }
                rest = rest[end.upperBound...]
                inside = false
            } else if let begin = rest.range(of: "<!--") {
                result += rest[..<begin.lowerBound]
                rest = rest[begin.upperBound...]
                inside = true
            } else {
                result += rest
                rest = ""
            }
        }
        return (result, inside)
    }
}
