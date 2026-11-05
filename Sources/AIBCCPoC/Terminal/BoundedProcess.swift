import Darwin
import Foundation

/// Children in their own process group (posix_spawn), with a deadline from
/// the start, capped output, and the whole group killed on timeout, cancel
/// and after the root exits (descendants holding the pipes). Every group is
/// registered under a tag while it runs; registration happens under the
/// same lock as the cancel check and the spawn, so turning activation off
/// or quitting can neither miss a starting child nor let a new one start.
enum BoundedProcess {
    struct Output {
        let stdout: Data
        /// Empty when stderr is merged into stdout.
        let stderr: Data
        /// Exit status of the root process.
        let status: Int32
    }

    enum Failure: Error, Equatable {
        /// Refused before spawning (cancelled or shutting down): no child ran.
        case notStarted
        case couldNotStart, cancelled, timedOut, monitorFailed
    }

    struct Options {
        var timeout: TimeInterval
        var outputLimit: Int
        var mergeStderr = false
        var tag = "child"
    }

    static let activationTag = "activation"
    private static let live = LiveGroups()

    /// Kills the running groups of `tag` now (new ones may still start).
    static func kill(tag: String) { live.kill(tag: tag) }

    /// App quit: no new child starts and every running group is killed.
    static func shutdown() { live.shutdown() }

    static var isShuttingDown: Bool { live.isShuttingDown }

    static func run(_ executable: URL, _ arguments: [String], cwd: URL, environment: [String: String],
                    options: Options, cancelled: @Sendable () -> Bool = { false }) -> Result<Output, Failure> {
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
        guard pipe(&out) == 0 else { return .failure(.couldNotStart) }
        if !options.mergeStderr, pipe(&err) != 0 {
            close(out[0]); close(out[1])
            return .failure(.couldNotStart)
        }
        let errWrite = options.mergeStderr ? out[1] : err[1]
        let started = live.start(tag: options.tag, cancelled: cancelled) {
            spawn(executable, arguments, cwd: cwd, environment: environment, stdin: nil, stdout: out[1], stderr: errWrite)
        }
        close(out[1])
        if !options.mergeStderr { close(err[1]) }
        guard case let .success(pid) = started else {
            close(out[0])
            if !options.mergeStderr { close(err[0]) }
            if case let .failure(failure) = started { return .failure(failure) }
            return .failure(.couldNotStart)
        }
        let stdout = Drain(out[0], limit: options.outputLimit)
        let stderr = options.mergeStderr ? nil : Drain(err[0], limit: options.outputLimit)
        let (result, status) = wait(pid, deadline: Date().addingTimeInterval(options.timeout), cancelled: cancelled)
        finish(pid)
        let output = Output(stdout: stdout.finish(), stderr: stderr?.finish() ?? Data(), status: status)
        return result.map { output }
    }

    /// For a child the caller talks to (stdin pipe): spawn registered under
    /// `tag`; the caller must call `finish(_:)`.
    static func startInteractive(_ executable: URL, _ arguments: [String], cwd: URL, environment: [String: String],
                                 stdin: Int32, stdout: Int32, tag: String) -> pid_t? {
        let started = live.start(tag: tag, cancelled: { false }) {
            spawn(executable, arguments, cwd: cwd, environment: environment, stdin: stdin, stdout: stdout, stderr: nil)
        }
        if case let .success(pid) = started { return pid }
        return nil
    }

    /// Kills the group, reaps the root, unregisters.
    static func finish(_ pid: pid_t) {
        Darwin.kill(-pid, SIGKILL)
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == 0 { waitpid(pid, &status, 0) }
        live.remove(pid)
    }

    private static func wait(_ pid: pid_t, deadline: Date, cancelled: () -> Bool) -> (Result<Void, Failure>, Int32) {
        var status: Int32 = 0
        while true {
            if cancelled() || live.isShuttingDown { return (.failure(.cancelled), -1) }
            if Date() >= deadline { return (.failure(.timedOut), -1) }
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                let exited = (status & 0x7F) == 0
                return (.success(()), exited ? (status >> 8) & 0xFF : 128 + (status & 0x7F))
            }
            if waited < 0 { return (.failure(.monitorFailed), -1) }
            usleep(50_000)
        }
    }

    private static func spawn(_ executable: URL, _ arguments: [String], cwd: URL, environment: [String: String],
                              stdin: Int32?, stdout: Int32, stderr: Int32?) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        if let stdin {
            posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        if let stderr {
            posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        } else {
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_addchdir_np(&actions, cwd.path)
        // Own process group; no inherited descriptor besides 0/1/2.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        return posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp) == 0 ? pid : nil
    }

    private final class LiveGroups: @unchecked Sendable {
        private let lock = NSLock()
        private var groups: [pid_t: String] = [:]
        /// Its own lock: `cancelled` runs under `lock` and may ask for it
        /// (the activation scheduler does). Read under `lock` it would be a
        /// re-entry into a non-recursive lock — a deadlock (Codex r6).
        private let stopLock = NSLock()
        private var stopping = false

        var isShuttingDown: Bool { stopLock.withLock { stopping } }

        /// Cancel check, spawn and registration as one step. `cancelled`
        /// runs with `lock` held: it may read `isShuttingDown` but must not
        /// start, kill or shut down a process.
        func start(tag: String, cancelled: () -> Bool, _ spawn: () -> pid_t?) -> Result<pid_t, Failure> {
            lock.withLock {
                guard !isShuttingDown, !cancelled() else { return .failure(.notStarted) }
                guard let pid = spawn() else { return .failure(.couldNotStart) }
                groups[pid] = tag
                return .success(pid)
            }
        }

        func remove(_ pid: pid_t) { lock.withLock { _ = groups.removeValue(forKey: pid) } }

        func kill(tag: String) {
            lock.withLock { groups.filter { $0.value == tag }.keys.forEach { Darwin.kill(-$0, SIGKILL) } }
        }

        /// Closes the gate first: a `start` that already holds `lock` either
        /// saw it closed or registers its group before the kill below.
        func shutdown() {
            stopLock.withLock { stopping = true }
            lock.withLock { groups.keys.forEach { Darwin.kill(-$0, SIGKILL) } }
        }
    }

    /// Reads a pipe to EOF on its own thread, keeping the first `limit` bytes.
    private final class Drain: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var data = Data()

        init(_ fd: Int32, limit: Int) {
            Thread.detachNewThread { [self] in
                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count <= 0 { break }
                    lock.withLock {
                        let keep = min(count, limit - data.count)
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
