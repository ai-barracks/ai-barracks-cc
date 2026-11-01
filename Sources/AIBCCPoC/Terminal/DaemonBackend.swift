import Darwin
import Foundation
import PtyProtocol

/// Opt-in PTY backend (`--backend=daemon`): AIBCCPtyDaemon owns the shells
/// so they survive an app quit, and panes render through libghostty's
/// in-memory backend (docs/spikes/pty-ownership.md, option B).
struct DaemonBackend: Sendable {
    let socketPath: String
    let executable: URL

    /// Session layout saved next to the socket; it belongs to that daemon.
    var sessionStoreURL: URL {
        URL(fileURLWithPath: socketPath + AppConstants.Daemon.sessionStoreSuffix)
    }

    var logURL: URL {
        URL(fileURLWithPath: socketPath + AppConstants.Daemon.logSuffix)
    }

    /// The daemon backend unless `--backend=exec`; nil if unreachable.
    static func fromArguments(_ arguments: [String] = CommandLine.arguments) -> DaemonBackend? {
        guard let socket = socketPath(for: arguments) else { return nil }
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent(AppConstants.Daemon.executableName),
            FileManager.default.isExecutableFile(atPath: executable.path)
        else { return nil }
        let backend = DaemonBackend(socketPath: socket, executable: executable)
        return backend.ensureRunning() ? backend : nil
    }

    /// Which socket a launch uses: explicit `--ptyd-socket=`, else the
    /// self-test socket for self-test runs, else the versioned default.
    static func socketPath(for arguments: [String]) -> String? {
        guard !arguments.contains(AppConstants.Daemon.execArgument) else { return nil }
        let prefix = AppConstants.Daemon.socketArgumentPrefix
        if let explicit = arguments.first(where: { $0.hasPrefix(prefix) }) { return String(explicit.dropFirst(prefix.count)) }
        let selfTest = arguments.contains { $0 == AppConstants.SelfTest.argument || $0.hasPrefix(AppConstants.SelfTest.onlyArgumentPrefix) }
        let name = selfTest ? AppConstants.Daemon.selfTestSocketName : PtyProtocol.defaultSocketName
        return ((AppConstants.Daemon.supportDirectory as NSString).expandingTildeInPath as NSString).appendingPathComponent(name)
    }

    /// Hangs up every session (the "세션 모두 종료" action and quitting
    /// with "keep sessions" off).
    func shutdownSessions() {
        Self.shutdownSessions(at: socketPath)
    }

    static func shutdownSessions(at socketPath: String) {
        _ = FrameRequest.send(Frame(.shutdown), to: socketPath)
    }

    /// Connects to a running daemon or starts one in its own session
    /// (setsid), detached from the app so it outlives it.
    func ensureRunning() -> Bool {
        if isReachable { return true }
        guard spawnDaemon() else { return false }
        let deadline = Date().addingTimeInterval(AppConstants.Daemon.startTimeout)
        while Date() < deadline {
            if isReachable { return true }
            usleep(AppConstants.Daemon.startPollMicroseconds)
        }
        return isReachable
    }

    /// Sessions the daemon still holds (alive or exited with output).
    func listSessions() -> [SessionInfo]? {
        guard let reply = FrameRequest.send(Frame(.list), to: socketPath, expecting: .sessions) else { return nil }
        return PtyProtocol.decode([SessionInfo].self, from: reply.payload)
    }

    /// Ends sessions no pane can reach any more (one connection).
    func killSessions(_ ids: [UUID]) {
        guard !ids.isEmpty, let fd = UnixSocket.connect(path: socketPath) else { return }
        defer { close(fd) }
        let frames = ids.reduce(into: Data()) { $0.append(Frame(.kill, session: $1).encoded()) }
        _ = frames.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
    }

    private var isReachable: Bool {
        guard let fd = UnixSocket.connect(path: socketPath) else { return false }
        close(fd)
        return true
    }

    private func spawnDaemon() -> Bool {
        let directory = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        // Own session, default signals, empty mask, and no app fds except
        // the three set below (POSIX_SPAWN_CLOEXEC_DEFAULT).
        var allSignals = sigset_t()
        var noSignals = sigset_t()
        sigfillset(&allSignals)
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        let logPath: String = logURL.path
        posix_spawn_file_actions_addopen(&actions, 2, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)

        let program: String = executable.path
        let words: [String] = [program, "--socket", socketPath]
        let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, program, &actions, &attributes, argv, environ)
        guard status == 0 else { return false }
        DaemonReaper.watch(pid)
        return true
    }
}

/// Builds the child's launch request. The environment is complete (the
/// app's plus the pane's) because the long-lived daemon's own must not leak.
enum DaemonLaunch {
    static func request(command: String?, workingDirectory: String?, environment: [String: String]) -> CreateRequest {
        let terminal = [
            "TERM": AppConstants.Daemon.term,
            "COLORTERM": AppConstants.Daemon.colorTerm,
            "TERM_PROGRAM": AppConstants.Daemon.termProgram,
        ]
        let fullEnvironment = ProcessInfo.processInfo.environment
            .merging(environment) { _, pane in pane }
            .merging(terminal) { _, term in term }
        let directory = workingDirectory ?? NSHomeDirectory()
        let (executable, argv): (String, [String]) = command.map {
            (AppConstants.Daemon.commandShell, [AppConstants.Daemon.commandShell, "-c", $0])
        } ?? {
            // Login shell, as a terminal starts it: argv[0] is "-zsh".
            let shell = loginShell()
            return (shell, ["-" + (shell as NSString).lastPathComponent])
        }()
        return CreateRequest(
            executable: executable, argv: argv, workingDirectory: directory, environment: fullEnvironment,
            columns: AppConstants.Daemon.placeholderColumns, rows: AppConstants.Daemon.placeholderRows
        )
    }

    private static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if path.hasPrefix("/") { return path }
        }
        return AppConstants.Daemon.fallbackLoginShell
    }
}

/// The daemon is the app's child until the app quits; reap it if it stops
/// first (test shutdown, idle exit) so it never lingers as a zombie.
private enum DaemonReaper {
    nonisolated(unsafe) private static var sources: [DispatchSourceProcess] = []
    private static let lock = NSLock()

    static func watch(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler {
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            source.cancel()
        }
        source.resume()
        lock.withLock { sources.append(source) }
    }
}
