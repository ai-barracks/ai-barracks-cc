import Foundation

/// Skills CRUD (v1 skills.rs parity) on a throwaway barrack under the temp
/// directory. Never runs `aib sync` and never touches the user's Trash.
@MainActor
struct SkillSuite {
    static let council = [
        "---", "name: council", "# discovery line below", "description: \"Use when a decision needs review: run a debate.\"",
        "argument-hint: \"<topic> [-m debate]\"", "allowed-tools: Bash(./scripts/council.sh *), Read, Write",
        "aib_version: \"1.1\"", "upstream: \"ai-barracks/scripts/council.sh\"", "growth_origin: \"manual\"", "---", "",
        "# LLM Council", "", "Body text.", "",
    ].joined(separator: "\n")

    func run() -> [TestResult] {
        [document(), files(), pathSafety()]
    }

    private func check(_ id: String, _ title: String, _ failures: [String], _ start: ContinuousClock.Instant) -> TestResult {
        .make(id, title, status: failures.isEmpty ? .pass : .fail, cause: .app,
              evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    private func document() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let raw = SkillSuite.council
        let fields = SkillDocument.fields(raw)
        if fields != SkillFields(description: "Use when a decision needs review: run a debate.", argumentHint: "<topic> [-m debate]",
                                 allowedTools: "Bash(./scripts/council.sh *), Read, Write") { failures.append("fields") }
        if SkillDocument.split(raw)?.body != "# LLM Council\n\nBody text.\n" { failures.append("body") }
        if (try? SkillDocument.patch(raw, fields: fields, body: SkillDocument.split(raw)?.body ?? "").get()) != raw { failures.append("unchanged") }
        var edited = fields
        edited.description = "Use when two models should debate a design."
        edited.argumentHint = ""
        let patched = (try? SkillDocument.patch(raw, fields: edited, body: "# New\n").get()) ?? ""
        for piece in ["description: \"Use when two models should debate a design.\"\n", "# discovery line below\n",
                      "upstream: \"ai-barracks/scripts/council.sh\"\n", "---\n\n# New\n"] where !patched.contains(piece) {
            failures.append("patch: \(piece.prefix(18))")
        }
        if patched.contains("argument-hint") { failures.append("empty optional removed") }
        var added = SkillFields(description: "Some long enough description text")
        added.allowedTools = "Read"
        let inserted = (try? SkillDocument.patch("---\nname: x\ndescription: d\n---\nbody\n", fields: added, body: "body\n").get()) ?? ""
        if inserted != "---\nname: x\ndescription: Some long enough description text\nallowed-tools: Read\n---\nbody\n" { failures.append("insert key") }
        if (try? SkillDocument.patch("---\nname: x\ndescription: d\n---", fields: SkillFields(description: "d"), body: "b").get()) != "---\nname: x\ndescription: d\n---\nb\n" {
            failures.append("fence at eof")
        }
        let folded = "---\nname: x\ndescription: >\n  long\n  text\n---\n"
        if SkillDocument.multilineKeys(folded) != [.description] { failures.append("multiline detect") }
        if case .success = SkillDocument.patch(folded, fields: SkillFields(description: "new one"), body: "") { failures.append("multiline must fail") }
        if case .success = SkillDocument.patch("---\nname: x\ndescription: a\ndescription: b\n---\n", fields: SkillFields(description: "c"), body: "") {
            failures.append("duplicate must fail")
        }
        if (try? SkillDocument.renamed(raw, to: "debate").get())?.hasPrefix("---\nname: debate\n# discovery line below\n") != true { failures.append("renamed") }
        let fresh = SkillDocument.render(slug: "open-pr", fields: SkillFields(description: "Use when: opening a PR", allowedTools: "Bash(gh *)"), body: "# Open PR")
        if SkillDocument.name(fresh) != "open-pr" || SkillDocument.fields(fresh).description != "Use when: opening a PR"
            || !fresh.contains("aib_version: \"1.1\"\ngrowth_origin: \"manual\"\n---\n\n# Open PR\n") { failures.append("render") }
        for bad in ["", "Upper", "-lead", "a/b", "..", "a.b", "1abc"] where SkillDocument.validate(slug: bad) == nil { failures.append("slug \(bad)") }
        return check("SK-02a", "SKILL.md 폼 = 한 줄씩 패치(주석·aib_version·upstream 보존), 여러 줄·중복 키는 거부, slug 규칙 = v1", failures, start)
    }

    private func files() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        guard let barrack = makeBarrack() else { return check("SK-02b", "Skills 파일 작업", ["temp barrack"], start) }
        defer { try? FileManager.default.removeItem(at: barrack) }
        let remove: SkillFiles.Remover = { try FileManager.default.removeItem(at: $0) }
        let content = SkillDocument.render(slug: "open-pr", fields: SkillFields(description: "Use when opening a pull request"), body: "# Open PR")
        if case .failure = SkillFiles.create(in: barrack, slug: "open-pr", content: content) { failures.append("create") }
        if SkillFiles.create(in: barrack, slug: "open-pr", content: content) != .failure(.exists("open-pr")) { failures.append("create twice") }
        if SkillFiles.list(in: barrack).map(\.slug) != ["open-pr"] || SkillFiles.list(in: barrack).first?.problem != nil { failures.append("list") }
        let file = barrack.appendingPathComponent("skills/open-pr/SKILL.md")
        let edited = content.replacingOccurrences(of: "# Open PR", with: "# Open a PR")
        if case .failure = SkillFiles.update(in: barrack, slug: "open-pr", original: content, edited: edited) { failures.append("update") }
        if SkillFiles.update(in: barrack, slug: "open-pr", original: content, edited: "x") != .failure(.conflict) { failures.append("update conflict") }
        if case .failure = SkillFiles.rename(in: barrack, from: "open-pr", to: "pull-request") { failures.append("rename") }
        let renamed = barrack.appendingPathComponent("skills/pull-request/SKILL.md")
        if FileManager.default.fileExists(atPath: file.path) || SkillFiles.list(in: barrack).first?.name != "pull-request"
            || (try? String(contentsOf: renamed, encoding: .utf8))?.contains("# Open a PR") != true { failures.append("rename result") }
        _ = SkillFiles.create(in: barrack, slug: "other", content: content)
        if SkillFiles.rename(in: barrack, from: "pull-request", to: "other") != .failure(.exists("other")) { failures.append("rename onto existing") }
        if SkillFiles.list(in: barrack).first(where: { $0.slug == "other" })?.problem == nil { failures.append("name mismatch flagged") }
        if case .failure = SkillFiles.remove(in: barrack, slug: "other", using: remove) { failures.append("remove") }
        if case .failure(.notFound("other")) = SkillFiles.remove(in: barrack, slug: "other", using: remove) {} else { failures.append("remove missing") }
        if case .success = SkillFiles.remove(in: barrack, slug: "..", using: remove) { failures.append("remove traversal") }
        return check("SK-02b", "Skills 생성·편집(충돌 감지)·이름 변경(name 갱신)·삭제 = v1, 중복·잘못된 slug 거부", failures, start)
    }

    private func pathSafety() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        guard let barrack = makeBarrack(), let outside = makeBarrack() else { return check("SK-02c", "Skills 경로 안전", ["temp"], start) }
        defer {
            try? FileManager.default.removeItem(at: barrack)
            try? FileManager.default.removeItem(at: outside)
        }
        let manager = FileManager.default
        let content = SkillDocument.render(slug: "real", fields: SkillFields(description: "Use when checking path safety"), body: "")
        _ = SkillFiles.create(in: outside, slug: "real", content: content)
        // skills/ itself pointing out of the barrack.
        try? manager.createSymbolicLink(at: barrack.appendingPathComponent("skills"), withDestinationURL: outside.appendingPathComponent("skills"))
        if case .failure(.unsafePath) = SkillFiles.skillsRoot(barrack) {} else { failures.append("skills root escape") }
        if !SkillFiles.list(in: barrack).isEmpty { failures.append("escaped root listed") }
        try? manager.removeItem(at: barrack.appendingPathComponent("skills"))
        try? manager.createDirectory(at: barrack.appendingPathComponent("skills"), withIntermediateDirectories: false)
        // A symlinked skill directory and a symlinked SKILL.md.
        try? manager.createSymbolicLink(at: barrack.appendingPathComponent("skills/linked"), withDestinationURL: outside.appendingPathComponent("skills/real"))
        try? manager.createDirectory(at: barrack.appendingPathComponent("skills/filelink"), withIntermediateDirectories: false)
        try? manager.createSymbolicLink(at: barrack.appendingPathComponent("skills/filelink/SKILL.md"),
                                        withDestinationURL: outside.appendingPathComponent("skills/real/SKILL.md"))
        if !SkillFiles.list(in: barrack).isEmpty { failures.append("symlinks listed") }
        for slug in ["linked", "filelink"] {
            if case .failure(.unsafePath) = SkillFiles.update(in: barrack, slug: slug, original: content, edited: "x") {} else { failures.append("update \(slug)") }
        }
        if case .failure = SkillFiles.rename(in: barrack, from: "filelink", to: "moved") {} else { failures.append("rename symlinked file") }
        if (try? String(contentsOf: outside.appendingPathComponent("skills/real/SKILL.md"), encoding: .utf8)) != content { failures.append("outside file changed") }
        return check("SK-02c", "Skills 경로 안전 = v1(배럭 밖 skills/·링크된 skill·링크된 SKILL.md는 목록 제외·쓰기 거부)", failures, start)
    }

    /// The real `aib sync` on a throwaway barrack under the temp directory
    /// (aib never registers temp paths) with its registry redirected to a
    /// temp file as well; the user's registry must be byte-identical after.
    func syncIntegration() async -> TestResult {
        let start = ContinuousClock.now
        let userRegistry = URL(fileURLWithPath: NSHomeDirectory() + "/.aib/barracks.json")
        let before = try? Data(contentsOf: userRegistry)
        guard let barrack = makeBarrack(), let scratch = makeBarrack() else { return check("SK-02d", "aib sync 연동", ["temp"], start) }
        defer {
            try? FileManager.default.removeItem(at: barrack)
            try? FileManager.default.removeItem(at: scratch)
        }
        let registry = scratch.appendingPathComponent("barracks.json")
        try? Data("[]".utf8).write(to: registry)
        try? Data("name: t\nversion: 0.1.0\ndescription: \"t\"\nmodels:\n  primary: x\n".utf8).write(to: barrack.appendingPathComponent("agent.yaml"))
        let sync = SkillSync.runner(registry: registry.path)
        var failures: [String] = []
        let content = SkillDocument.render(slug: "open-pr", fields: SkillFields(description: "Use when opening a pull request"), body: "# Open PR")
        _ = SkillFiles.create(in: barrack, slug: "open-pr", content: content)
        let first = await sync(barrack)
        if first != .ok { failures.append("sync: \(first)") }
        let link = { (slug: String) in try? FileManager.default.destinationOfSymbolicLink(atPath: barrack.appendingPathComponent(".claude/skills/\(slug)").path) }
        if link("open-pr") != "../../skills/open-pr" { failures.append("link created") }
        if (try? String(contentsOf: barrack.appendingPathComponent("CLAUDE.md"), encoding: .utf8))?.contains("`open-pr`") != true { failures.append("catalog") }
        _ = SkillFiles.rename(in: barrack, from: "open-pr", to: "pull-request")
        if await sync(barrack) != .ok || link("pull-request") != "../../skills/pull-request" || link("open-pr") != nil { failures.append("rename relinked") }
        if case .ok = await sync(scratch) { failures.append("non-barrack must fail") }
        if (try? Data(contentsOf: userRegistry)) != before { failures.append("USER REGISTRY CHANGED") }
        if (try? String(contentsOf: registry, encoding: .utf8))?.contains(barrack.lastPathComponent) == true { failures.append("temp barrack registered") }
        return check("SK-02d", "저장 후 aib sync = v1(.claude/skills 링크·CLAUDE.md 카탈로그 갱신, 실패 감지) · 사용자 레지스트리 무변경", failures, start)
    }

    private func makeBarrack() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-skill-\(UUID().uuidString)")
        return (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil ? url : nil
    }
}
