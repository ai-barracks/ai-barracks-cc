import Darwin
import Foundation

/// One activation of one CLI (v1 activate_with_binary): confirm the
/// subscription login, send the single minimal request, accept only an
/// exact "OK". Every child runs in its own process group in a temp
/// directory with provider credentials stripped from its environment, its
/// output capped, and is killed with its descendants on timeout or cancel.
enum ActivationRunner {
    static let outputLimit = 64 * 1024
    static let authTimeout: TimeInterval = 20
    static let requestTimeout: TimeInterval = 120

    /// v1 find_binary: Homebrew, /usr/local, ~/.local, then PATH.
    static func findBinary(_ name: String, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> URL? {
        let fixed = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        let directories = fixed + (path?.split(separator: ":").map(String.init) ?? [])
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func authArguments(_ provider: ActivationProvider) -> [String] {
        provider == .claude ? ["auth", "status", "--json"] : ["login", "status"]
    }

    /// v1 request_args, verbatim: no tools, no MCP, no hooks, no settings
    /// sources, no session persistence, one turn.
    static func requestArguments(_ provider: ActivationProvider) -> [String] {
        switch provider {
        case .claude:
            ["-p", ActivationSchedule.prompt, "--output-format", "json", "--no-session-persistence", "--max-turns", "1",
             "--permission-mode", "dontAsk", "--tools", "", "--disallowedTools", "mcp__*", "--strict-mcp-config",
             "--mcp-config", "{\"mcpServers\":{}}", "--settings", "{\"disableAllHooks\":true}", "--setting-sources", "",
             "--system-prompt", "Reply exactly OK. Do not use tools."]
        case .codex:
            ["exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
             "--sandbox", "read-only", "-c", "approval_policy=\"never\"", "-c", "web_search=\"disabled\"",
             "--disable", "hooks", "--disable", "plugins", "--disable", "apps", "--disable", "shell_tool",
             "--disable", "unified_exec", "--disable", "multi_agent", "--disable", "browser_use",
             "--disable", "computer_use", "--disable", "image_generation", "--disable", "skill_mcp_dependency_install",
             "--disable", "memories", ActivationSchedule.prompt]
        }
    }

    /// Subscription login only (v1 account_auth): API keys and unknown
    /// methods are refused.
    static func isSubscriptionLogin(_ provider: ActivationProvider, _ output: Data) -> Bool {
        switch provider {
        case .claude:
            guard let value = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any] else { return false }
            return value["loggedIn"] as? Bool == true && value["authMethod"] as? String == "claude.ai"
                && value["apiProvider"] as? String == "firstParty"
        case .codex:
            return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "Logged in using ChatGPT"
        }
    }

    /// v1 valid_response: an exact "OK" and nothing that used a tool.
    static func isValidResponse(_ provider: ActivationProvider, _ output: Data) -> Bool {
        switch provider {
        case .claude:
            guard let value = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any] else { return false }
            return value["type"] as? String == "result" && value["subtype"] as? String == "success"
                && value["is_error"] as? Bool == false
                && (value["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "OK"
        case .codex:
            var completed = false
            var reply = false
            for line in output.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                guard let value = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return false }
                let item = value["item"] as? [String: Any]
                let itemType = item?["type"] as? String
                switch value["type"] as? String {
                case "error", "turn.failed": return false
                case "turn.completed": completed = true
                case "item.completed" where itemType == "agent_message":
                    reply = (item?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "OK"
                case "item.started", "item.completed":
                    if let itemType, !["agent_message", "reasoning"].contains(itemType) { return false }
                default: break
                }
            }
            return completed && reply
        }
    }

    /// Runs the auth check then the request. `cancelled` is polled.
    static func activate(_ provider: ActivationProvider, binary: URL, authTimeout: TimeInterval = authTimeout,
                         requestTimeout: TimeInterval = requestTimeout,
                         cancelled: @escaping @Sendable () -> Bool) -> Result<Void, ActivationFailure> {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-activation-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)) != nil else {
            return .failure("Cannot create isolated activation directory")
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let environment = CodexModelProbe.sanitizedEnvironment()
        let auth = BoundedProcess.run(binary, authArguments(provider), cwd: scratch, environment: environment,
                                      timeout: authTimeout, cancelled: cancelled)
        guard case let .success(authOutput) = auth else { return auth.map { _ in () } }
        // Codex prints its login status on stderr. Auth output is never stored.
        guard isSubscriptionLogin(provider, authOutput.stdout) || isSubscriptionLogin(provider, authOutput.stderr) else {
            return .failure("Subscription login not confirmed; API/unknown auth refused")
        }
        let request = BoundedProcess.run(binary, requestArguments(provider), cwd: scratch, environment: environment,
                                         timeout: requestTimeout, cancelled: cancelled)
        guard case let .success(output) = request else { return request.map { _ in () } }
        return isValidResponse(provider, output.stdout) ? .success(()) : .failure("CLI did not return a successful OK result; not retried")
    }
}

/// A child in its own process group (posix_spawn), stdin /dev/null,
/// stdout/stderr capped, killed with its group on timeout or cancel and
/// after it exits (descendants still holding the pipes).
enum BoundedProcess {
    struct Output {
        let stdout: Data
        let stderr: Data
    }

    /// Process groups still running, so quitting can kill them at once
    /// (v1 cancel_work) instead of waiting for the next poll.
    private static let live = LiveGroups()

    static func killAll() {
        live.killAll()
    }

    private final class LiveGroups: @unchecked Sendable {
        private let lock = NSLock()
        private var groups = Set<pid_t>()

        func insert(_ pid: pid_t) { lock.withLock { _ = groups.insert(pid) } }
        func remove(_ pid: pid_t) { lock.withLock { _ = groups.remove(pid) } }
        func killAll() { lock.withLock { groups.forEach { kill(-$0, SIGKILL) } } }
    }

    static func run(_ executable: URL, _ arguments: [String], cwd: URL, environment: [String: String],
                    timeout: TimeInterval, cancelled: @Sendable () -> Bool) -> Result<Output, ActivationFailure> {
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
        guard pipe(&out) == 0, pipe(&err) == 0 else { return .failure("CLI could not start") }
        var pid: pid_t = 0
        let spawned = spawn(executable, arguments, cwd: cwd, environment: environment, stdout: out[1], stderr: err[1], pid: &pid)
        close(out[1])
        close(err[1])
        guard spawned else {
            close(out[0])
            close(err[0])
            return .failure("CLI could not start")
        }
        live.insert(pid)
        defer { live.remove(pid) }
        let stdout = Drain(out[0]), stderr = Drain(err[0])
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        let result: Result<Void, ActivationFailure>
        while true {
            if cancelled() {
                result = .failure("Cancelled after settings changed")
                break
            }
            if Date() >= deadline {
                result = .failure("CLI timed out; not retried")
                break
            }
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                result = exitedNormally(status) ? .success(()) : .failure("CLI exited unsuccessfully; not retried")
                break
            }
            if waited < 0 {
                result = .failure("Cannot monitor CLI process")
                break
            }
            usleep(100_000)
        }
        kill(-pid, SIGKILL)
        if waitpid(pid, &status, WNOHANG) == 0 { waitpid(pid, &status, 0) }
        let output = Output(stdout: stdout.finish(), stderr: stderr.finish())
        return result.map { _ in output }
    }

    private static func exitedNormally(_ status: Int32) -> Bool {
        (status & 0x7F) == 0 && ((status >> 8) & 0xFF) == 0
    }

    private static func spawn(_ executable: URL, _ arguments: [String], cwd: URL, environment: [String: String],
                              stdout: Int32, stderr: Int32, pid: inout pid_t) -> Bool {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd.path)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        return posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp) == 0
    }

    /// Reads a pipe to EOF on its own thread, keeping the first bytes only.
    private final class Drain: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var data = Data()

        init(_ fd: Int32) {
            Thread.detachNewThread { [self] in
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count <= 0 { break }
                    lock.withLock {
                        let keep = min(count, ActivationRunner.outputLimit - data.count)
                        if keep > 0 { data.append(contentsOf: buffer[0..<keep]) }
                    }
                }
                close(fd)
                done.signal()
            }
        }

        func finish() -> Data {
            _ = done.wait(timeout: .now() + 2)
            return lock.withLock { data }
        }
    }
}
