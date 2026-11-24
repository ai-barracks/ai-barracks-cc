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
        let auth = run(binary, authArguments(provider), scratch, environment, authTimeout, cancelled)
        guard case let .success(authOutput) = auth else { return auth.map { _ in () } }
        // Codex prints its login status on stderr. Auth output is never stored.
        guard isSubscriptionLogin(provider, authOutput.stdout) || isSubscriptionLogin(provider, authOutput.stderr) else {
            return .failure("Subscription login not confirmed; API/unknown auth refused")
        }
        let request = run(binary, requestArguments(provider), scratch, environment, requestTimeout, cancelled)
        guard case let .success(output) = request else { return request.map { _ in () } }
        return isValidResponse(provider, output.stdout) ? .success(()) : .failure("CLI did not return a successful OK result; not retried")
    }

    /// One child of the activation group; a nonzero exit is a failure.
    private static func run(_ binary: URL, _ arguments: [String], _ cwd: URL, _ environment: [String: String],
                            _ timeout: TimeInterval, _ cancelled: @escaping @Sendable () -> Bool) -> Result<BoundedProcess.Output, ActivationFailure> {
        let options = BoundedProcess.Options(timeout: timeout, outputLimit: outputLimit, tag: BoundedProcess.activationTag)
        switch BoundedProcess.run(binary, arguments, cwd: cwd, environment: environment, options: options, cancelled: cancelled) {
        case let .success(output) where output.status == 0: return .success(output)
        case .success: return .failure("CLI exited unsuccessfully; not retried")
        case .failure(.cancelled), .failure(.notStarted): return .failure("Cancelled after settings changed")
        case .failure(.timedOut): return .failure("CLI timed out; not retried")
        case .failure(.couldNotStart): return .failure("CLI could not start")
        case .failure(.monitorFailed): return .failure("Cannot monitor CLI process")
        }
    }
}
