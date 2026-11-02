import Foundation

/// One changed path under the barrack (`git status` porcelain v2).
struct GitChange: Equatable, Identifiable {
    enum Kind: Equatable { case tracked, renamed, unmerged, untracked }

    let kind: Kind
    /// Index / worktree status letters ("." = unchanged).
    let index: Character
    let worktree: Character
    /// Path relative to the repository root.
    let path: String
    let originalPath: String?

    var id: String { path }
    var isStaged: Bool { kind != .untracked && index != "." }
    var isModified: Bool { kind != .untracked && worktree != "." }
}

/// v1 `get_git_status`, repo- and monorepo-aware: counts and changes are
/// limited to the barrack directory (`-- .` from inside it), branch and
/// ahead/behind are the repository's.
struct GitState: Equatable {
    var branch = ""
    var upstream: String?
    var ahead = 0
    var behind = 0
    var changes: [GitChange] = []

    var staged: Int { changes.filter(\.isStaged).count }
    var modified: Int { changes.filter(\.isModified).count }
    var untracked: Int { changes.filter { $0.kind == .untracked }.count }

    /// Parses `git status --porcelain=v2 --branch -z` output.
    static func parse(_ output: String) -> GitState {
        var state = GitState()
        var records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let record = records.popFirst() {
            let fields = record.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "#":
                header(fields, into: &state)
            case "1" where fields.count >= 9:
                state.changes.append(change(.tracked, fields[1], fields[8...].joined(separator: " "), nil))
            case "2" where fields.count >= 10:
                // In -z output a rename's original path is the next record.
                state.changes.append(change(.renamed, fields[1], fields[9...].joined(separator: " "), records.popFirst()))
            case "u" where fields.count >= 11:
                state.changes.append(change(.unmerged, fields[1], fields[10...].joined(separator: " "), nil))
            case "?":
                state.changes.append(GitChange(kind: .untracked, index: "?", worktree: "?", path: String(record.dropFirst(2)), originalPath: nil))
            default:
                break
            }
        }
        return state
    }

    private static func header(_ fields: [String], into state: inout GitState) {
        guard fields.count >= 3 else { return }
        let value = fields[2...].joined(separator: " ")
        switch fields[1] {
        case "branch.head": state.branch = value
        case "branch.upstream": state.upstream = value
        case "branch.ab":
            let numbers = fields[2...].compactMap { Int($0.dropFirst()) }
            if numbers.count == 2 { (state.ahead, state.behind) = (numbers[0], numbers[1]) }
        default: break
        }
    }

    private static func change(_ kind: GitChange.Kind, _ xy: String, _ path: String, _ original: String?) -> GitChange {
        let letters = Array(xy)
        return GitChange(kind: kind, index: letters.first ?? ".", worktree: letters.count > 1 ? letters[1] : ".", path: path, originalPath: original)
    }
}

/// Git for one barrack (v1 git.rs). Every command runs from the barrack
/// directory with `-- .` where a path applies, so a barrack inside a
/// larger repository only ever stages, commits and lists its own files.
struct GitRepository {
    let directory: String
    /// Extra environment (self-tests isolate the user's git config).
    var environment: [String: String] = [:]

    struct Outcome: Equatable {
        let ok: Bool
        let output: String
    }

    struct Info: Equatable {
        var isRepo = false
        /// Barrack path inside the repository ("" at the root).
        var prefix = ""
        var root = ""
        var remote = ""
        var state = GitState()
        var log: [LogEntry] = []

        var isSubPath: Bool { !prefix.isEmpty }
    }

    struct LogEntry: Equatable, Identifiable {
        let hash: String
        let subject: String
        let author: String
        let when: String

        var id: String { hash }
    }

    func run(_ arguments: [String]) async -> Outcome {
        // No terminal: a credential prompt must fail, not wait forever.
        let env = environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { current, _ in current }
        let result = await ProcessOutput.runWithStatus(URL(fileURLWithPath: "/usr/bin/git"), ["-C", directory] + arguments,
                                                       in: directory, environment: env)
        return Outcome(ok: result.status == 0, output: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func info(logCount: Int = 30) async -> Info {
        let prefix = await run(["rev-parse", "--show-prefix"])
        guard prefix.ok else { return Info() }
        var info = Info(isRepo: true, prefix: prefix.output)
        info.root = await run(["rev-parse", "--show-toplevel"]).output
        let remote = await run(["remote", "get-url", "origin"])
        info.remote = remote.ok ? remote.output : ""
        info.state = GitState.parse(await raw(["status", "--porcelain=v2", "--branch", "-z", "--", "."]))
        let separator = "\u{1F}"
        let log = await run(["log", "-\(logCount)", "--format=%h\(separator)%s\(separator)%an\(separator)%ar", "--", "."])
        info.log = log.ok ? log.output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: Character(separator), omittingEmptySubsequences: false).map(String.init)
            return parts.count == 4 ? LogEntry(hash: parts[0], subject: parts[1], author: parts[2], when: parts[3]) : nil
        } : []
        return info
    }

    /// Stages and commits only the barrack's own changes (`--only` with a
    /// pathspec): other paths already staged in the repository stay staged
    /// and out of this commit (v1 `git add -- <barrack>; git commit` took
    /// them along).
    func commit(message: String) async -> Outcome {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return Outcome(ok: false, output: "커밋 메시지가 비었습니다") }
        let add = await run(["add", "-A", "--", "."])
        guard add.ok else { return add }
        return await run(["commit", "-m", message, "--", "."])
    }

    /// `git push`, setting the upstream when the branch has none.
    func push(_ state: GitState) async -> Outcome {
        guard state.upstream == nil else { return await run(["push"]) }
        return await run(["push", "-u", "origin", state.branch])
    }

    /// Porcelain output keeps leading spaces and NULs: no trimming.
    private func raw(_ arguments: [String]) async -> String {
        let env = environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { current, _ in current }
        return await ProcessOutput.runWithStatus(URL(fileURLWithPath: "/usr/bin/git"), ["-C", directory] + arguments,
                                                 in: directory, environment: env).output
    }
}
