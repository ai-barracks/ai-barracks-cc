import Foundation

/// v1 parity for the structured editors: the cases of CC v1.6.1
/// documentPatch.test.ts and rulesDocument.test.ts, run on the Swift port.
@MainActor
struct DocumentSuite {
    func run() -> [TestResult] {
        [patchPrimitives(), patchBulletRuns(), rulesParsing(), rulesPatching(), soulParsing(), soulPatching(),
         growthParsing(), growthPatching(), yamlParsing(), yamlPatching()]
    }

    static let richRules = [
        "<!-- AIB:RULES:v1 — auto-accumulated -->", "# Rules", "", "preamble prose", "",
        "## Must Always", "<!-- pinned by ops -->", "- communicate in Korean", "- write tests", "",
        "## Must Never", "- skip code review", "- bypass hooks", "",
        "## Learned", "- log before mutating shared state", "",
        "## Notes", "custom section content", "```python", "- not a managed bullet", "```", "",
        "<!-- AIB:RULES:END -->",
    ].joined(separator: "\n")

    static let richSoul = [
        "<!-- AIB:SOUL:v1 — keep this structure -->", "# Agent Identity", "",
        "## Name", "<!-- pinned name below -->", "Aria", "",
        "## Expertise", "- TypeScript", "- React", "",
        "## Personality", "- calm", "- precise", "",
        "## Core Values", "- truth", "- clarity", "",
        "## Constraints", "- ko-first", "",
        "## Notes", "custom section content", "```python", "- not a managed bullet", "```", "",
        "<!-- AIB:SOUL:END -->",
    ].joined(separator: "\n")

    static let richGrowth = [
        "<!-- AIB:OWNERSHIP — keep -->", "# Growth Protocol", "",
        "## Decision Table — 발견 즉시 기록 (CRITICAL)", "",
        "세션 **종료 시**가 아니라, **발견하는 즉시** 아래 표에 따라 기록한다.", "",
        "| 세션 중 이벤트 | 기록 위치 | 예시 |", "|---------------|-----------|------|",
        "| 새 사실/아키텍처 결정 발견 | `wiki/topics/` | 배포 순서 |", "| 사용자가 행동 교정 | `RULES.md` | 파일 수정 전 재읽기 |", "",
        "**NOT growth-worthy** — 기록하지 않을 것:", "- 단순 git commit", "- 일회성 사용자 선호", "",
        "## End-of-Session Audit", "", "세션 종료 전 누락을 점검한다.", "",
        "## Custom Section", "custom prose should stay", "```md", "| 세션 중 이벤트 | fake | table |",
        "**NOT growth-worthy** — fake inside code", "- fake not-growth item", "```",
    ].joined(separator: "\n")

    static let richYaml = [
        "# agent config", "name: old-agent # keep name comment", "version: 1.4.0",
        "description: \"Old description # not comment\" # keep desc comment", "",
        "models:", "  # model comment", "  primary: gpt-5.5 # keep primary comment", "  fallback:", "    - claude-opus-4-8", "    - gemini-3", "",
        "memory:", "  sessions: sessions/", "", "skills:", "  discovery: auto", "", "custom_policy:", "  x: y", "", "aib_version: 1.1",
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
        return check("RU-01a", "RULES 해석·변경 없음이면 원문 그대로(LF·CRLF·끝 줄바꿈 없음)", failures, start)
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
        return check("RU-01b", "RULES 패치 = v1(한 섹션만 변경·빈 섹션 채우기·빈 파일 템플릿·모호하면 실패)", failures, start)
    }

    private func soulParsing() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        if SoulDocument.parse(DocumentSuite.richSoul) != SoulData(name: "Aria", expertise: ["TypeScript", "React"], personality: ["calm", "precise"],
                                                                 coreValues: ["truth", "clarity"], constraints: ["ko-first"]) {
            failures.append("rich parse")
        }
        let fenced = "## Expertise\n\n```\n- not a managed bullet\n- another fake\n```\n\n- TypeScript\n- React\n"
        if SoulDocument.parse(fenced).expertise != ["TypeScript", "React"] { failures.append("fenced bullets") }
        if SoulDocument.parse("## Name\n\n<!-- ownership: human -->\n\nReal Name\nsecondary line").name != "Real Name" {
            failures.append("managed name line")
        }
        if SoulDocument.parse("# Title only\n") != SoulData() { failures.append("absent sections") }
        let crlf = DocumentSuite.richSoul.replacingOccurrences(of: "\n", with: "\r\n")
        for raw in [DocumentSuite.richSoul, crlf] where (try? SoulDocument.patch(raw, to: SoulDocument.parse(raw)).get()) != raw {
            failures.append("unchanged round trip")
        }
        return check("SD-01a", "SOUL 해석 = v1(이름 줄·목록 4개, 코드 블록·주석 무시) · 변경 없으면 원문 그대로", failures, start)
    }

    private func soulPatching() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let rich = DocumentSuite.richSoul
        var next = SoulDocument.parse(rich)
        next.expertise.append("Vitest")
        let patched = (try? SoulDocument.patch(rich, to: next).get()) ?? ""
        for piece in ["## Expertise\n- TypeScript\n- React\n- Vitest\n", "## Personality\n- calm\n- precise\n",
                      "<!-- pinned name below -->\nAria\n", "## Notes\ncustom section content\n```python\n- not a managed bullet\n```",
                      "<!-- AIB:SOUL:END -->"] where !patched.contains(piece) { failures.append("list: \(piece.prefix(20))") }
        let empty = "<!-- preamble comment -->\n# Identity\n\n## Name\nAria\n\n## Expertise\n- TypeScript\n\n## Constraints\n\n## Notes\ncustom\n"
        var constraints = SoulDocument.parse(empty)
        constraints.constraints = ["ko-first", "no PII"]
        let inserted = (try? SoulDocument.patch(empty, to: constraints).get()) ?? ""
        if !inserted.contains("## Constraints\n- ko-first\n- no PII\n") || !inserted.contains("## Notes\ncustom\n") { failures.append("fill empty list") }
        var renamed = SoulDocument.parse(rich)
        renamed.name = "Nyx"
        let named = (try? SoulDocument.patch(rich, to: renamed).get()) ?? ""
        if !named.contains("## Name\n<!-- pinned name below -->\nNyx\n") || named.contains("Aria") { failures.append("rename") }
        let pending = "## Name\n<!-- pending -->\n\n## Expertise\n- TS\n"
        var first = SoulDocument.parse(pending)
        first.name = "Aria"
        if (try? SoulDocument.patch(pending, to: first).get())?.contains("## Name\nAria\n<!-- pending -->\n") != true { failures.append("insert name") }
        let failing: [(String, (inout SoulData) -> Void, SoulDocument.Field, MarkdownPatch.Failure)] = [
            ("## Name\nAria\n\n## Expertise\n- TS\n", { $0.constraints = ["k"] }, .constraints, .sectionNotFound),
            ("## Expertise\n- TS\n\n## Expertise\n- dup\n", { $0.expertise = ["x"] }, .expertise, .multipleSections),
            ("## Expertise\n- TS\n- React\n\nprose\n\n- extra\n", { $0.expertise = ["x"] }, .expertise, .multipleBulletRuns),
            ("## Expertise\n- TS\n", { $0.name = "Aria" }, .name, .sectionNotFound),
        ]
        for (raw, change, field, reason) in failing {
            var data = SoulDocument.parse(raw)
            change(&data)
            if case let .failure(got) = SoulDocument.patch(raw, to: data), got == SoulDocument.Failure(field: field, reason: reason) { continue }
            failures.append("fail closed \(field.rawValue) \(reason)")
        }
        return check("SD-01b", "SOUL 패치 = v1(바뀐 목록·이름 줄만, 빈 섹션 채우기, 모호하면 실패)", failures, start)
    }

    private func growthParsing() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let data = GrowthDocument.parse(DocumentSuite.richGrowth)
        if data != GrowthData(decisionTable: [DecisionRow(event: "새 사실/아키텍처 결정 발견", location: "`wiki/topics/`", example: "배포 순서"),
                                              DecisionRow(event: "사용자가 행동 교정", location: "`RULES.md`", example: "파일 수정 전 재읽기")],
                              notGrowthWorthy: ["단순 git commit", "일회성 사용자 선호"]) { failures.append("rich parse") }
        let crlf = DocumentSuite.richGrowth.replacingOccurrences(of: "\n", with: "\r\n")
        for raw in [DocumentSuite.richGrowth, crlf] where (try? GrowthDocument.patch(raw, to: GrowthDocument.parse(raw)).get()) != raw {
            failures.append("unchanged round trip")
        }
        // Parsing reads exactly the rows patching rewrites (v1 deviation).
        let split = "| 세션 중 이벤트 | 위치 | 예시 |\n|---|---|---|\n| A | B | C |\n| x --- y | B | C |\n\n| later | table | row |\n"
        if GrowthDocument.parse(split).decisionTable.map(\.event) != ["A", "x --- y"] { failures.append("table extent") }
        let emptyCell = "| 세션 중 이벤트 | 위치 | 예시 |\n|---|---|---|\n| A |  | C |\n"
        if GrowthDocument.parse(emptyCell).decisionTable != [DecisionRow(event: "A", location: "", example: "C")] { failures.append("empty cell") }
        return check("GR-01a", "GROWTH 해석 = v1(Decision Table·NOT growth-worthy, 코드 블록 무시) · 변경 없으면 원문 그대로", failures, start)
    }

    private func growthPatching() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let rich = DocumentSuite.richGrowth
        var rows = GrowthDocument.parse(rich)
        rows.decisionTable.append(DecisionRow(event: "오류/수정 검토", location: "`sessions/{id}.md`", example: "Retries"))
        let table = (try? GrowthDocument.patch(rich, to: rows).get()) ?? ""
        for piece in ["| 세션 중 이벤트 | 기록 위치 | 예시 |\n|---------------|-----------|------|\n", "| 오류/수정 검토 | `sessions/{id}.md` | Retries |\n",
                      "**NOT growth-worthy** — 기록하지 않을 것:\n- 단순 git commit\n- 일회성 사용자 선호\n",
                      "## Custom Section\ncustom prose should stay\n```md\n| 세션 중 이벤트 | fake | table |\n"] where !table.contains(piece) {
            failures.append("table: \(piece.prefix(16))")
        }
        let emptyTable = "# Growth Protocol\n\n| 세션 중 이벤트 | 기록 위치 | 예시 |\n|---------------|-----------|------|\n\n**NOT growth-worthy** — 기록하지 않을 것:\n- skip\n"
        var first = GrowthDocument.parse(emptyTable)
        first.decisionTable = [DecisionRow(event: "E", location: "L", example: "X")]
        if (try? GrowthDocument.patch(emptyTable, to: first).get())?.contains("|------|\n| E | L | X |\n\n**NOT growth-worthy**") != true {
            failures.append("insert into empty table")
        }
        var list = GrowthDocument.parse(rich)
        list.notGrowthWorthy = ["단순 git commit", "이미 wiki에 있는 반복"]
        let listed = (try? GrowthDocument.patch(rich, to: list).get()) ?? ""
        if !listed.contains("- 단순 git commit\n- 이미 wiki에 있는 반복\n\n## End-of-Session Audit") || !listed.contains("| 사용자가 행동 교정 |") {
            failures.append("list")
        }
        let emptyList = "| 세션 중 이벤트 | 기록 위치 | 예시 |\n|---|---|---|\n| E | L | X |\n\n**NOT growth-worthy** — 기록하지 않을 것:\n\n## End-of-Session Audit"
        var filled = GrowthDocument.parse(emptyList)
        filled.notGrowthWorthy = ["skip one", "skip two"]
        if (try? GrowthDocument.patch(emptyList, to: filled).get())?.contains("기록하지 않을 것:\n- skip one\n- skip two\n\n## End") != true {
            failures.append("fill empty list")
        }
        let header = "| 세션 중 이벤트 | 기록 위치 | 예시 |\n"
        let anchor = "**NOT growth-worthy** — 기록하지 않을 것:\n"
        let failing: [(String, (inout GrowthData) -> Void, GrowthDocument.Failure)] = [
            ("# Growth\n\n" + anchor + "- x\n", { $0.decisionTable = [DecisionRow(event: "E")] }, .init(field: .decisionTable, reason: .headerNotFound)),
            (header + "|---|---|---|\n| A | B | C |\n\n" + header + "|---|---|---|\n| D | E | F |\n",
             { $0.decisionTable = [DecisionRow(event: "X")] }, .init(field: .decisionTable, reason: .multipleHeaders)),
            (header + "| A | B | C |\n\n" + anchor + "- x", { $0.decisionTable = [DecisionRow(event: "X")] },
             .init(field: .decisionTable, reason: .separatorNotFound)),
            (header + "|---|---|---|\n| A || C |\n", { $0.decisionTable = [DecisionRow(event: "X")] }, .init(field: .decisionTable, reason: .malformedRow)),
            (anchor + "- x\n\n" + anchor + "- y", { $0.notGrowthWorthy = ["z"] }, .init(field: .notGrowthWorthy, reason: .multipleAnchors)),
            (anchor + "- x\n\nprose interruption\n\n- y\n\n## End", { $0.notGrowthWorthy = ["z"] },
             .init(field: .notGrowthWorthy, reason: .multipleBulletRuns)),
            ("# Growth\n", { $0.notGrowthWorthy = ["z"] }, .init(field: .notGrowthWorthy, reason: .anchorNotFound)),
        ]
        for (raw, change, want) in failing {
            var data = GrowthDocument.parse(raw)
            change(&data)
            if case let .failure(got) = GrowthDocument.patch(raw, to: data), got == want { continue }
            failures.append("fail closed \(want.reason)")
        }
        let twoTables = header + "|---|---|---|\n| A | B | C |\n\n" + anchor + "- x\n\n" + header + "|---|---|---|\n| D | E | F |\n"
        if GrowthDocument.blocked(twoTables).map(\.field) != [.decisionTable] || !GrowthDocument.blocked(rich).isEmpty {
            failures.append("blocked preflight")
        }
        if !SoulDocument.blocked(DocumentSuite.richSoul).isEmpty || !RulesDocument.blocked(DocumentSuite.richRules).isEmpty
            || RulesDocument.blocked("## Must Always\n- a\nprose\n- b\n").map(\.field) != [.mustAlways, .mustNever, .learned] {
            failures.append("blocked preflight soul/rules")
        }
        return check("GR-01b", "GROWTH 패치 = v1(표 행·목록만 교체, 빈 표·목록 채우기, 모호하면 실패) + 저장 불가 섹션 사전 표시", failures, start)
    }

    private func yamlParsing() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        if AgentYamlDocument.parse(DocumentSuite.richYaml) != AgentConfig(name: "old-agent", version: "1.4.0", description: "Old description # not comment",
                                                                         primaryModel: "gpt-5.5", fallbackModels: ["claude-opus-4-8", "gemini-3"], aibVersion: "1.1") {
            failures.append("rich parse")
        }
        let outside = "name: a\nversion: 1\ndescription: d\nmodels:\n  primary: model-primary\nmetadata:\n  primary: metadata-primary\n  fallback:\n    - metadata-fallback\naib_version: 1.1"
        let parsed = AgentYamlDocument.parse(outside)
        if parsed.primaryModel != "model-primary" || !parsed.fallbackModels.isEmpty { failures.append("keys outside models") }
        let crlf = DocumentSuite.richYaml.replacingOccurrences(of: "\n", with: "\r\n")
        for raw in [DocumentSuite.richYaml, crlf] where (try? AgentYamlDocument.patch(raw, to: AgentYamlDocument.parse(raw)).get()) != raw {
            failures.append("unchanged round trip")
        }
        if AgentYamlDocument.otherKeys(DocumentSuite.richYaml) != ["memory", "skills", "custom_policy"] { failures.append("other keys") }
        if YamlScalar.unquote(#""a\"b\\c\n""#) != "a\"b\\c\n" || YamlScalar.unquote("'it''s'") != "it's" { failures.append("unquote") }
        return check("YM-01a", "agent.yaml 해석 = v1(주석·따옴표 인식, models 밖 키 무시) · 변경 없으면 원문 그대로", failures, start)
    }

    private func yamlPatching() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let rich = DocumentSuite.richYaml
        let base = AgentYamlDocument.parse(rich)
        let patched = { (raw: String, change: (inout AgentConfig) -> Void) -> Result<String, AgentYamlDocument.Failure> in
            var next = AgentYamlDocument.parse(raw)
            change(&next)
            return AgentYamlDocument.patch(raw, to: next)
        }
        let renamed = (try? patched(rich) { $0.name = "new-agent" }.get()) ?? ""
        for piece in ["name: new-agent # keep name comment", "description: \"Old description # not comment\" # keep desc comment",
                      "memory:\n  sessions: sessions/", "custom_policy:\n  x: y"] where !renamed.contains(piece) { failures.append("scalar: \(piece.prefix(16))") }
        if (try? patched(rich) { $0.description = "New # value" }.get())?.contains("description: \"New # value\" # keep desc comment") != true {
            failures.append("quoted description")
        }
        let plain = "name: a\nversion: 1\ndescription: old\nmodels:\n  primary: p\naib_version: 1.1"
        if (try? patched(plain) { $0.description = "New # value" }.get())?.contains("description: \"New # value\"") != true { failures.append("quote when needed") }
        if (try? patched(plain) { $0.description = "[draft] x" }.get())?.contains("description: \"[draft] x\"") != true { failures.append("indicator quoted") }
        let models = (try? patched(rich) { $0.primaryModel = "gpt-6"; $0.fallbackModels = ["claude-new"] }.get()) ?? ""
        if !models.contains("  # model comment\n  primary: gpt-6 # keep primary comment\n  fallback:\n    - claude-new\n") || models.contains("gemini-3") {
            failures.append("models")
        }
        let commented = "name: a\nversion: 1\ndescription: d\nmodels:\n  primary: p\n  fallback:\n    - f1 # first fallback\n    - \"f2 # value\" # second fallback\naib_version: 1.1"
        if AgentYamlDocument.parse(commented).fallbackModels != ["f1", "f2 # value"] { failures.append("item comments parse") }
        let items = (try? patched(commented) { $0.fallbackModels = ["f1-new", "f2-new # value"] }.get()) ?? ""
        if !items.contains("    - f1-new # first fallback") || !items.contains("    - \"f2-new # value\" # second fallback") { failures.append("item comments") }
        let inserted = (try? patched(plain) { $0.fallbackModels = ["f1", "f2"] }.get()) ?? ""
        if !inserted.contains("models:\n  primary: p\n  fallback:\n    - f1\n    - f2\naib_version") { failures.append("insert fallback") }
        if (try? patched(inserted) { $0.fallbackModels = [] }.get())?.contains("models:\n  primary: p\naib_version") != true { failures.append("remove fallback") }
        // v1 glued the inserted block onto a last line without a newline.
        if (try? patched("name: a\nmodels:\n  primary: p") { $0.fallbackModels = ["f"] }.get()) != "name: a\nmodels:\n  primary: p\n  fallback:\n    - f\n" {
            failures.append("insert at eof")
        }
        // The aib template's empty flow list (v1 appended items after "[]").
        let flowEmpty = "models:\n  primary: p  # meta\n  fallback: []  # none yet\n\nmemory:\n  x: y\n"
        if (try? patched(flowEmpty) { $0.fallbackModels = ["a"] }.get()) != "models:\n  primary: p  # meta\n  fallback:  # none yet\n    - a\n\nmemory:\n  x: y\n" {
            failures.append("empty flow list")
        }
        let failing: [(String, (inout AgentConfig) -> Void, AgentYamlDocument.Failure)] = [
            ("version: 1\nmodels:\n  primary: p\n", { $0.name = "x" }, .init(field: .name, reason: .keyNotFound)),
            ("name: a\nname: b\nmodels:\n  primary: p\n", { $0.name = "x" }, .init(field: .name, reason: .multipleKeys)),
            ("name: a\nversion: 1\ndescription: d\naib_version: 1.1\n", { $0.primaryModel = "x" }, .init(field: .primaryModel, reason: .modelsNotFound)),
            ("models:\n  primary: p\n  fallback: [a, b]\n", { $0.fallbackModels = ["x"] }, .init(field: .fallbackModels, reason: .fallbackNotBlockList)),
            ("models:\n  fallback:\n    - a\n    # note\n    - b\n", { $0.fallbackModels = ["x"] }, .init(field: .fallbackModels, reason: .fallbackNotContiguous)),
            ("models:\n  fallback:\n    - a\n\n    - b\n", { $0.fallbackModels = ["x"] }, .init(field: .fallbackModels, reason: .fallbackNotContiguous)),
        ]
        for (raw, change, want) in failing {
            if case let .failure(got) = patched(raw, change), got == want { continue }
            failures.append("fail closed \(want.reason)")
        }
        if !AgentYamlDocument.blocked(rich).isEmpty || base.aibVersion != "1.1" { failures.append("blocked rich") }
        return check("YM-01b", "agent.yaml 패치 = v1(주석·따옴표 유지, fallback 삽입·삭제, 모호하면 실패) + v1 YAML 손상 4건 수정", failures, start)
    }
}
