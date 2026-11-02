import Foundation

/// Git destination (v1 git.rs parity + monorepo fix) on throwaway repos
/// under the temp directory, with the user's git config shut out.
@MainActor
struct GitSuite {
    private let environment = [
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
    ]

    func run() async -> [TestResult] {
        [parsing(), await monorepo()]
    }

    private func check(_ id: String, _ title: String, _ failures: [String], _ start: ContinuousClock.Instant) -> TestResult {
        .make(id, title, status: failures.isEmpty ? .pass : .fail, cause: .app,
              evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    private func parsing() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let output = ["# branch.oid abc", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -1",
                      "1 M. N... 100644 100644 100644 a b sub/file one.md", "1 .D N... 100644 100644 000000 a b sub/gone.md",
                      "2 R. N... 100644 100644 100644 a b R100 sub/new.md", "sub/old.md",
                      "u UU N... 100644 100644 100644 100644 a b c sub/conflict.md", "? sub/new file.txt", ""].joined(separator: "\0")
        let state = GitState.parse(output)
        if state.branch != "main" || state.upstream != "origin/main" || state.ahead != 2 || state.behind != 1 { failures.append("branch") }
        if state.changes.map(\.path) != ["sub/file one.md", "sub/gone.md", "sub/new.md", "sub/conflict.md", "sub/new file.txt"] {
            failures.append("paths \(state.changes.map(\.path))")
        }
        if state.changes.first(where: { $0.kind == .renamed })?.originalPath != "sub/old.md" { failures.append("rename origin") }
        if state.staged != 3 || state.modified != 2 || state.untracked != 1 { failures.append("counts \(state.staged)/\(state.modified)/\(state.untracked)") }
        if GitState.parse("# branch.oid (initial)\0# branch.head main\0").upstream != nil { failures.append("no upstream") }
        return check("GT-01a", "git status porcelain v2 해석(분기·ahead/behind·이름 변경·충돌·공백 경로) = v1 카운트", failures, start)
    }

    private func monorepo() async -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-git-\(UUID().uuidString)")
        let barrack = root.appendingPathComponent("barrack")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: barrack, withIntermediateDirectories: true)
        let write = { (url: URL, text: String) in try? Data(text.utf8).write(to: url) }
        let repo = GitRepository(directory: root.path, environment: environment)
        let sub = GitRepository(directory: barrack.path, environment: environment)
        write(root.appendingPathComponent("outside.txt"), "o\n")
        write(barrack.appendingPathComponent("a.md"), "a\n")
        _ = await repo.run(["init", "-q", "-b", "main"])
        _ = await repo.run(["add", "-A"])
        _ = await repo.run(["commit", "-q", "-m", "root: initial"])
        write(root.appendingPathComponent("outside.txt"), "o2\n")
        _ = await repo.run(["add", "outside.txt"])
        write(barrack.appendingPathComponent("a.md"), "a2\n")
        write(barrack.appendingPathComponent("b.md"), "b\n")
        let before = await sub.info()
        if before.prefix != "barrack/" || !before.isSubPath { failures.append("prefix \(before.prefix)") }
        if before.state.changes.map(\.path).sorted() != ["barrack/a.md", "barrack/b.md"] { failures.append("filtered \(before.state.changes.map(\.path))") }
        let committed = await sub.commit(message: "barrack: change")
        if !committed.ok { failures.append("commit: \(committed.output.prefix(80))") }
        let files = await repo.run(["show", "--name-only", "--format=", "HEAD"]).output.split(separator: "\n").map(String.init).sorted()
        if files != ["barrack/a.md", "barrack/b.md"] { failures.append("commit took \(files)") }
        if await repo.run(["diff", "--cached", "--name-only"]).output != "outside.txt" { failures.append("outside staging lost") }
        let after = await sub.info()
        if !after.state.changes.isEmpty || after.log.map(\.subject) != ["barrack: change", "root: initial"] { failures.append("after \(after.log.map(\.subject))") }
        if (await sub.commit(message: "  ")).ok { failures.append("empty message accepted") }
        let pushed = await sub.push(after.state)
        if pushed.ok { failures.append("push without remote succeeded") }
        if await GitRepository(directory: FileManager.default.temporaryDirectory.path, environment: environment).info().isRepo {
            failures.append("temp dir is a repo")
        }
        return check("GT-01b", "모노레포 배럭: 변경·로그·커밋이 배럭 경로만(밖의 staged 파일은 커밋에 안 들어감), 원격 없으면 push 실패(대기 없음)",
                     failures, start)
    }
}
