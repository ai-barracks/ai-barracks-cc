import Darwin
import Foundation

/// The PATH the user's own terminal has. The app runs aib and agents through
/// `zsh -lc`, a login shell that skips ~/.zshrc — where the official
/// installers put ~/.local/bin (2026-11-25: a new Mac's app could not find
/// claude; this Mac's app ran Homebrew's stale Claude 2.1.118 while the
/// terminal ran ~/.local/bin's 2.1.331). It is read once from the user's
/// login shell run interactively, as Terminal starts it, and put back after
/// the profile files ran (they reorder PATH).
enum UserShell {
    private static let begin = "__AIB_PATH_BEGIN__"
    private static let end = "__AIB_PATH_END__"
    private static let store = Store()

    /// The PATH read at launch; nil until read, or when reading failed.
    static var path: String? { store.value }

    /// Put in front of a `zsh -lc` command: "export PATH='…'; ", or "".
    static var pathPrefix: String { prefix(for: path) }

    static func prefix(for path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        return "export PATH=" + AgentLauncher.shellQuote(path) + "; "
    }

    /// `zsh` arguments that run `command` with the user's PATH.
    static func loginArguments(_ command: String) -> [String] {
        ["-lc", pathPrefix + command]
    }

    /// Reads the PATH once (at launch). A shell that hangs or prints no
    /// markers leaves it unknown; aib still finds claude/codex itself.
    static func resolve() async {
        store.set(await read())
    }

    /// `shell -l -i -c`, with `environment` added (tests point ZDOTDIR at
    /// fixtures). `printenv` prints the exported PATH in zsh, bash and fish alike.
    static func read(shell: String = loginShell, environment: [String: String] = [:],
                     timeout: TimeInterval = AppConstants.UserShell.timeout) async -> String? {
        let script = "echo \(begin); /usr/bin/printenv PATH; echo \(end)"
        let result = await ProcessOutput.runWithStatus(URL(fileURLWithPath: shell), ["-l", "-i", "-c", script],
                                                      in: NSHomeDirectory(), environment: environment, timeout: timeout)
        return parse(result.output)
    }

    /// The PATH between the markers; whatever the rc files print around it is ignored.
    static func parse(_ output: String) -> String? {
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(where: { $0.hasSuffix(begin) }), start + 2 < lines.count,
              lines[start + 2].hasPrefix(end) else { return nil }
        let path = lines[start + 1]
        return path.hasPrefix("/") ? path : nil
    }

    /// The user's login shell (their account record), else zsh.
    static var loginShell: String {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return AppConstants.Daemon.fallbackLoginShell }
        let value = String(cString: shell)
        return FileManager.default.isExecutableFile(atPath: value) ? value : AppConstants.Daemon.fallbackLoginShell
    }

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? { lock.withLock { stored } }
        func set(_ value: String?) { lock.withLock { stored = value } }
    }
}
