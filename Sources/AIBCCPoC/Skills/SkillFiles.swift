import Foundation

/// One skill in the catalog (v1 SkillCard).
struct SkillEntry: Identifiable, Equatable {
    let slug: String
    let file: URL
    let name: String
    let description: String
    /// Why the catalog cannot read this SKILL.md as aib expects, if so.
    let problem: String?

    var id: String { slug }
}

/// `skills/<slug>/` operations, ported from CC v1.6.1 `skills.rs` with the
/// same path safety: the skills directory must resolve inside the barrack,
/// and a symlinked skill directory or SKILL.md is never followed (listing
/// skips it, writes refuse it). Deleting moves to the Trash (v1 removed the
/// directory for good).
enum SkillFiles {
    enum Failure: Error, Equatable {
        case invalidSlug(String), unsafePath(String), exists(String), notFound(String), io(String), conflict

        var message: String {
            switch self {
            case let .invalidSlug(text): text
            case let .unsafePath(text): "안전하지 않은 경로: \(text)"
            case let .exists(slug): "이미 있는 skill입니다: \(slug)"
            case let .notFound(slug): "skill을 찾을 수 없습니다: \(slug)"
            case let .io(text): "파일 작업 실패: \(text)"
            case .conflict: "편집하는 동안 다른 곳이 SKILL.md를 고쳤습니다. 다시 불러온 뒤 편집하세요."
            }
        }
    }

    /// Moves a skill directory out of the barrack (the Trash in the app;
    /// self-tests pass a plain removal so nothing reaches the user's Trash).
    typealias Remover = @Sendable (URL) throws -> Void
    static let moveToTrash: Remover = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    static func list(in barrack: URL) -> [SkillEntry] {
        guard case let .success(root?) = skillsRoot(barrack) else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().compactMap { slug in
            let directory = root.appendingPathComponent(slug)
            let file = directory.appendingPathComponent("SKILL.md")
            guard kind(directory) == .typeDirectory, kind(file) == .typeRegular else { return nil }
            guard let raw = try? String(contentsOf: file, encoding: .utf8) else {
                return SkillEntry(slug: slug, file: file, name: slug, description: "", problem: "SKILL.md를 읽을 수 없습니다")
            }
            let name = SkillDocument.name(raw) ?? ""
            let description = SkillDocument.fields(raw).description
            let problem: String? = SkillDocument.split(raw) == nil ? "frontmatter(---) 없음"
                : name.isEmpty ? "name 없음" : name != slug ? "name '\(name)'이 디렉터리 '\(slug)'와 다름"
                : description.isEmpty ? "description 없음" : nil
            return SkillEntry(slug: slug, file: file, name: name.isEmpty ? slug : name, description: description, problem: problem)
        }
    }

    static func create(in barrack: URL, slug: String, content: String) -> Result<URL, Failure> {
        if let message = SkillDocument.validate(slug: slug) { return .failure(.invalidSlug(message)) }
        let root: URL
        switch skillsRoot(barrack, create: true) {
        case let .success(found?): root = found
        case .success(nil): return .failure(.io("skills 디렉터리를 만들지 못했습니다"))
        case let .failure(failure): return .failure(failure)
        }
        let directory = root.appendingPathComponent(slug)
        guard kind(directory) == nil else { return .failure(.exists(slug)) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let file = directory.appendingPathComponent("SKILL.md")
            try Data(content.utf8).write(to: file, options: .withoutOverwriting)
            return .success(file)
        } catch {
            return .failure(.io(error.localizedDescription))
        }
    }

    /// Writes `edited` only if SKILL.md still holds `original`.
    static func update(in barrack: URL, slug: String, original: String, edited: String) -> Result<URL, Failure> {
        let file: URL
        switch skillFile(barrack, slug) {
        case let .success(found): file = found
        case let .failure(failure): return .failure(failure)
        }
        switch DocumentEditing.save(edited: edited, original: original, to: file) {
        case .saved, .unchanged: return .success(file)
        case .conflict: return .failure(.conflict)
        case .failed: return .failure(.io("SKILL.md 저장 실패"))
        }
    }

    /// Moves `skills/<old>` to `skills/<new>` and sets `name:` to the new slug.
    /// The move is not undone if the name update fails (v1 spec §3.2); the
    /// result says so and the catalog shows the mismatch.
    static func rename(in barrack: URL, from old: String, to new: String) -> Result<URL, Failure> {
        if let message = SkillDocument.validate(slug: new) { return .failure(.invalidSlug(message)) }
        guard case .success = skillFile(barrack, old), case let .success(root?) = skillsRoot(barrack) else {
            return .failure(.notFound(old))
        }
        let target = root.appendingPathComponent(new)
        guard kind(target) == nil else { return .failure(.exists(new)) }
        do {
            try FileManager.default.moveItem(at: root.appendingPathComponent(old), to: target)
        } catch {
            return .failure(.io(error.localizedDescription))
        }
        let file = target.appendingPathComponent("SKILL.md")
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return .failure(.io("이름을 바꾼 뒤 SKILL.md를 읽지 못했습니다")) }
        switch SkillDocument.renamed(raw, to: new) {
        case let .success(updated):
            switch DocumentEditing.save(edited: updated, original: raw, to: file) {
            case .saved, .unchanged: return .success(file)
            case .conflict: return .failure(.conflict)
            case .failed: return .failure(.io("디렉터리는 옮겼지만 name을 저장하지 못했습니다"))
            }
        case let .failure(failure):
            return .failure(.io("디렉터리는 옮겼지만 name을 고치지 못했습니다(\(failure)). 원문 편집으로 name을 \(new)로 바꾸세요."))
        }
    }

    static func remove(in barrack: URL, slug: String, using remover: Remover = moveToTrash) -> Result<Void, Failure> {
        if let message = SkillDocument.validate(slug: slug) { return .failure(.invalidSlug(message)) }
        guard case let .success(root?) = skillsRoot(barrack) else { return .failure(.notFound(slug)) }
        let directory = root.appendingPathComponent(slug)
        guard kind(directory) == .typeDirectory else { return .failure(.notFound(slug)) }
        do {
            try remover(directory)
            return .success(())
        } catch {
            return .failure(.io(error.localizedDescription))
        }
    }

    // MARK: - Path safety

    /// The file type without following a final symlink (lstat), or nil.
    static func kind(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    static func canonical(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `<barrack>/skills` resolved inside the barrack; nil when absent
    /// (created when asked). A broken symlink or a link out of the barrack
    /// is an error, not "absent".
    static func skillsRoot(_ barrack: URL, create: Bool = false) -> Result<URL?, Failure> {
        let directory = barrack.appendingPathComponent("skills")
        switch kind(directory) {
        case nil:
            guard create else { return .success(nil) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            } catch {
                return .failure(.io(error.localizedDescription))
            }
            return skillsRoot(barrack)
        case .typeDirectory?, .typeSymbolicLink?:
            guard let base = canonical(barrack), let resolved = canonical(directory),
                  resolved.hasPrefix(base + "/"), kind(URL(fileURLWithPath: resolved)) == .typeDirectory else {
                return .failure(.unsafePath("skills 디렉터리가 배럭 밖을 가리킵니다"))
            }
            return .success(URL(fileURLWithPath: resolved))
        default:
            return .failure(.unsafePath("skills가 디렉터리가 아닙니다"))
        }
    }

    /// An existing `skills/<slug>/SKILL.md` that is a real file in a real directory.
    static func skillFile(_ barrack: URL, _ slug: String) -> Result<URL, Failure> {
        if let message = SkillDocument.validate(slug: slug) { return .failure(.invalidSlug(message)) }
        let root: URL
        switch skillsRoot(barrack) {
        case let .success(found?): root = found
        case .success(nil): return .failure(.notFound(slug))
        case let .failure(failure): return .failure(failure)
        }
        let directory = root.appendingPathComponent(slug)
        let file = directory.appendingPathComponent("SKILL.md")
        switch (kind(directory), kind(file)) {
        case (.typeDirectory?, .typeRegular?): return .success(file)
        case (nil, _), (.typeDirectory?, nil): return .failure(.notFound(slug))
        default: return .failure(.unsafePath("skills/\(slug)는 심볼릭 링크이거나 일반 파일이 아닙니다"))
        }
    }
}
