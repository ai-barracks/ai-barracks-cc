import Foundation

/// v1 parity for the structured editors: the cases of CC v1.6.1
/// documentPatch.test.ts and rulesDocument.test.ts, run on the Swift port.
@MainActor
struct DocumentSuite {
    func run() -> [TestResult] {
        [patchPrimitives(), patchBulletRuns(), rulesParsing(), rulesPatching()]
    }

    static let richRules = [
        "<!-- AIB:RULES:v1 — auto-accumulated -->", "# Rules", "", "preamble prose", "",
        "## Must Always", "<!-- pinned by ops -->", "- communicate in Korean", "- write tests", "",
        "## Must Never", "- skip code review", "- bypass hooks", "",
        "## Learned", "- log before mutating shared state", "",
        "## Notes", "custom section content", "```python", "- not a managed bullet", "```", "",
        "<!-- AIB:RULES:END -->",
    ].joined(separator: "\n")

    private func check(_ id: String, _ title: String, _ failures: [String], _ start: ContinuousClock.Instant) -> TestResult {
        .make(id, title, status: failures.isEmpty ? .pass : .fail, cause: .app,
              evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    private func patchPrimitives() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        for text in ["", "a", "a\nb", "a\nb\n", "a\r\nb\r\n", "a\r\nb", "x\n\ny\r\n\r\nz"]
        where MarkdownPatch.splitLines(text).joined() != text { failures.append("split round trip: \(text.debugDescription)") }
        let eols = [("none", "\n"), ("a\nb\n", "\n"), ("a\r\nb\r\nc\n", "\r\n"), ("a\r\nb\n", "\n")]
        for (text, want) in eols where MarkdownPatch.detectEol(text) != want { failures.append("eol \(text.debugDescription)") }
        let crlf = DocumentSuite.richRules.replacingOccurrences(of: "\n", with: "\r\n")
        for text in [DocumentSuite.richRules, crlf, "", "just prose\nno headings"]
        where MarkdownPatch.sections(text).map(\.raw).joined() != text { failures.append("sections round trip") }
        let fenced = MarkdownPatch.sections("# A\n```\n# not heading\n```\n~~~\n## nor\n~~~\n## B\n").compactMap(\.heading)
        if fenced != ["A", "B"] { failures.append("fenced headings: \(fenced)") }
        let hashes = MarkdownPatch.sections("## Title#\n## Other #\n").compactMap(\.heading)
        if hashes != ["Title#", "Other"] { failures.append("trailing #: \(hashes)") }
        let four = MarkdownPatch.sections("````\n```\n# inside\n````\n# out\n").compactMap(\.heading)
        if four != ["out"] { failures.append("4-backtick fence: \(four)") }
        return check("DP-01a", "Markdown 줄·EOL·섹션 분할 = v1 documentPatch(바이트 보존, 코드 블록 인식)", failures, start)
    }

    private func patchBulletRuns() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let doc = "# T\n\n## S\n<!-- c -->\nintro\n- a\n- b\ntail\n\n## O\n- x\n"
        let patch = { (raw: String, bullets: [String]) in MarkdownPatch.patchBulletRun(raw, level: 2, heading: "S", bullets: bullets) }
        if (try? patch(doc, ["a", "b", "c"]).get()) != "# T\n\n## S\n<!-- c -->\nintro\n- a\n- b\n- c\ntail\n\n## O\n- x\n" {
            failures.append("replace run")
        }
        if (try? patch(doc, ["a", "b"]).get()) != doc { failures.append("no-op") }
        let crlf = doc.replacingOccurrences(of: "\n", with: "\r\n")
        if (try? patch(crlf, ["a"]).get()) != crlf.replacingOccurrences(of: "- a\r\n- b\r\n", with: "- a\r\n") { failures.append("crlf") }
        if (try? patch("## S\n  * a\n", ["z"]).get()) != "## S\n  * z\n" { failures.append("indented style") }
        if (try? patch("## S\n- a", ["a", "b"]).get()) != "## S\n- a\n- b" { failures.append("no trailing eol") }
        let expect = { (raw: String, want: MarkdownPatch.Failure, name: String) in
            if case let .failure(got) = patch(raw, ["z"]), got == want { return }
            failures.append(name)
        }
        expect("## X\n- a\n", .sectionNotFound, "not found")
        expect("## S\nprose\n", .noBulletRun, "no bullets")
        expect("## S\n- a\n## S\n- b\n", .multipleSections, "multiple sections")
        expect("## S\n```\n- fenced\n```\n", .noBulletRun, "only fenced bullets")
        expect("## S\n- a\nprose\n- b\n", .multipleBulletRuns, "multiple runs")
        if (try? patch("## S\n```\n- fenced\n```\n- real\n", ["new"]).get()) != "## S\n```\n- fenced\n```\n- new\n" {
            failures.append("fenced ignored")
        }
        return check("DP-01b", "글머리 목록 교체 = v1(나머지 바이트 보존, CRLF·들여쓰기 유지, 모호하면 실패)", failures, start)
    }

    private func rulesParsing() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let data = RulesDocument.parse(DocumentSuite.richRules)
        if data != RulesData(mustAlways: ["communicate in Korean", "write tests"], mustNever: ["skip code review", "bypass hooks"],
                             learned: ["log before mutating shared state"]) { failures.append("rich parse") }
        if RulesDocument.parse("# Rules\n") != RulesData() || RulesDocument.parse("") != RulesData() { failures.append("empty") }
        let crlf = DocumentSuite.richRules.replacingOccurrences(of: "\n", with: "\r\n")
        for raw in [DocumentSuite.richRules, crlf] where (try? RulesDocument.patch(raw, to: RulesDocument.parse(raw)).get()) != raw {
            failures.append("unchanged round trip")
        }
        return check("RD-01a", "RULES 해석·변경 없음이면 원문 그대로(LF·CRLF·끝 줄바꿈 없음)", failures, start)
    }

    private func rulesPatching() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        var next = RulesDocument.parse(DocumentSuite.richRules)
        next.mustAlways.append("use timezones")
        let patched = (try? RulesDocument.patch(DocumentSuite.richRules, to: next).get()) ?? ""
        for piece in ["## Must Always\n<!-- pinned by ops -->\n- communicate in Korean\n- write tests\n- use timezones\n",
                      "## Must Never\n- skip code review\n- bypass hooks\n", "<!-- AIB:RULES:END -->",
                      "## Notes\ncustom section content\n```python\n- not a managed bullet\n```", "preamble prose"]
        where !patched.contains(piece) { failures.append("update one: \(piece.prefix(20))") }
        let empty = "<!-- p -->\n# Rules\n\n## Must Always\n- k\n\n## Must Never\n- r\n\n## Learned\n\n## Notes\ncustom\n"
        var learned = RulesDocument.parse(empty)
        learned.learned = ["always log", "never trust input"]
        let inserted = (try? RulesDocument.patch(empty, to: learned).get()) ?? ""
        if !inserted.contains("## Learned\n- always log\n- never trust input\n") || !inserted.contains("## Notes\ncustom\n") {
            failures.append("insert into empty")
        }
        if (try? RulesDocument.patch("", to: RulesData(mustAlways: ["a"])).get()) != "# Rules\n\n## Must Always\n- a\n\n## Must Never\n\n## Learned\n" {
            failures.append("empty raw template")
        }
        let failing: [(String, MarkdownPatch.Failure)] = [
            ("# Rules\n## Must Never\n- a\n", .sectionNotFound),
            ("## Must Always\n- a\n## Must Always\n- b\n", .multipleSections),
            ("## Must Always\n- a\nprose\n- b\n", .multipleBulletRuns),
        ]
        for (raw, want) in failing {
            if case let .failure(got) = RulesDocument.patch(raw, to: RulesData(mustAlways: ["z"])), got.reason == want { continue }
            failures.append("fail closed \(want)")
        }
        return check("RD-01b", "RULES 패치 = v1(한 섹션만 변경·빈 섹션 채우기·빈 파일 템플릿·모호하면 실패)", failures, start)
    }
}
