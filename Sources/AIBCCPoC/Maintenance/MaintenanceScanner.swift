import Foundation

/// One item in the 정비 queue (spec §8): something only the user should
/// decide. Reading (scan) and doing (`command`, run in a terminal pane with
/// a dry-run first) stay separate.
struct MaintenanceItem: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable { case seal, clean, gc, wikiLint, skills, versionDrift }

    let kind: Kind
    let title: String
    let count: Int
    let details: [String]
    let command: String

    var id: String { kind.rawValue }
}

/// Runs aib's read-only checks for one barrack and turns their output
/// into queue items. Parsing is separate so it can be tested without aib.
enum MaintenanceScanner {
    static func scan(barrack: Barrack) async -> [MaintenanceItem] {
        let path = barrack.path
        async let verify = run("aib sessions verify --quiet", in: path)
        async let clean = run("aib sessions clean --dry-run", in: path)
        async let gc = run("aib sessions gc --dry-run", in: path)
        async let lint = run("aib wiki lint", in: path)
        async let skills = run("aib skills check .", in: path)
        async let cli = run("aib version", in: path)
        let agentVersion = (try? String(contentsOfFile: path + "/agent.yaml", encoding: .utf8))
            .flatMap { yamlValue("aib_version", in: $0) }
        return parse(verify: await verify, clean: await clean, gc: await gc, lint: await lint,
                     skills: await skills, cliVersion: await cli, barrackVersion: agentVersion, path: path)
    }

    static func parse(verify: String, clean: String, gc: String, lint: String, skills: String,
                      cliVersion: String, barrackVersion: String?, path: String) -> [MaintenanceItem] {
        let quoted = AgentLauncher.shellQuote(path)
        var items: [MaintenanceItem] = []
        let changed = lines(verify)
        if !changed.isEmpty {
            items.append(.init(kind: .seal, title: "봉인 후 바뀐 세션 기록", count: changed.count, details: changed,
                               command: "aib sessions verify"))
        }
        let removable = lines(clean).filter { $0.contains("Would delete") }
        if !removable.isEmpty {
            items.append(.init(kind: .clean, title: "빈 세션 파일 정리", count: removable.count, details: removable,
                               command: confirmThenApply("aib sessions clean --dry-run", "aib sessions clean")))
        }
        let reaped = lines(gc).filter { !$0.lowercased().contains("nothing") }
        if !reaped.isEmpty {
            items.append(.init(kind: .gc, title: "죽은 liveness·멈춘 세션 정리", count: reaped.count, details: reaped,
                               command: confirmThenApply("aib sessions gc --dry-run", "aib sessions gc")))
        }
        if let issues = firstNumber(after: "Wiki lint:", in: lint), issues > 0 {
            items.append(.init(kind: .wikiLint, title: "Wiki 점검 경고", count: issues,
                               details: Array(lines(lint).filter { $0.contains("[") }.prefix(20)),
                               command: confirmThenApply("aib wiki lint", "aib wiki lint --fix")))
        }
        let skillProblems = lines(skills).filter { !$0.contains("[OK]") }
        if !skillProblems.isEmpty {
            items.append(.init(kind: .skills, title: "Skills 연결 어긋남", count: skillProblems.count,
                               details: skillProblems, command: "aib skills doctor ."))
        }
        // `aib version` prints "aib v1.6.0": take the dotted version, without the "v".
        let cli = cliVersion.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression).map { String(cliVersion[$0]) }
        if let cli, let barrackVersion, cli != barrackVersion {
            items.append(.init(kind: .versionDrift, title: "배럭 프로토콜 \(barrackVersion) → aib \(cli)", count: 1,
                               details: ["aib sync로 템플릿·프로토콜을 맞춥니다"],
                               command: confirmThenApply("aib sync --dry-run \(quoted)", "aib sync \(quoted)")))
        }
        return items
    }

    /// Shows the dry run, waits for Enter, then applies (CC v1.6.1 Sync).
    static func confirmThenApply(_ dryRun: String, _ apply: String) -> String {
        "\(dryRun) && printf '\\n--- Enter를 누르면 적용, Ctrl+C로 취소 ---\\n' && read && \(apply)"
    }

    // MARK: - Helpers

    private static func run(_ command: String, in directory: String) async -> String {
        await AibShell.run(command, in: directory)
    }
}

/// Runs a command in the user's login shell (PATH finds aib), in a directory.
enum AibShell {
    static func run(_ command: String, in directory: String) async -> String {
        await ProcessOutput.run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", command], in: directory)
    }
}

/// Output of a child process, read while it runs: reading only after exit
/// deadlocks once the output fills the 64 KiB pipe (git status of a big
/// repo, a long lint).
enum ProcessOutput {
    static func run(_ executable: URL, _ arguments: [String], in directory: String) async -> String {
        await runWithStatus(executable, arguments, in: directory).output
    }

    /// Output (stdout and stderr together) and exit status. The child runs
    /// in its own process group under BoundedProcess: a deadline from the
    /// start, capped output, the group killed on timeout and after the root
    /// exits. Cannot start → -1; timed out → `unknownStatus`. (Foundation's
    /// waitUntilExit once hung a GCD worker forever, 2026-11-02; a
    /// background descendant holding the pipe hung the read, r5.)
    static func runWithStatus(_ executable: URL, _ arguments: [String], in directory: String,
                              environment: [String: String] = [:],
                              timeout: TimeInterval = AppConstants.ChildProcess.timeout) async -> (output: String, status: Int32) {
        let env = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let options = BoundedProcess.Options(timeout: timeout, outputLimit: AppConstants.ChildProcess.outputLimit, mergeStderr: true)
        let result = await Task.detached {
            BoundedProcess.run(executable, arguments, cwd: URL(fileURLWithPath: directory), environment: env, options: options)
        }.value
        switch result {
        case let .success(output): return (String(decoding: output.stdout, as: UTF8.self), output.status)
        case .failure(.couldNotStart), .failure(.notStarted): return ("", -1)
        case .failure: return ("", AppConstants.ChildProcess.unknownStatus)
        }
    }
}

extension MaintenanceScanner {
    static func lines(_ output: String) -> [String] {
        output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func firstNumber(after marker: String, in output: String) -> Int? {
        guard let line = lines(output).first(where: { $0.contains(marker) }) else { return nil }
        let tail = line.components(separatedBy: marker).last ?? ""
        return tail.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
    }

    private static func yamlValue(_ key: String, in text: String) -> String? {
        text.split(separator: "\n").first { $0.hasPrefix(key + ":") }
            .map { $0.dropFirst(key.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
    }
}
