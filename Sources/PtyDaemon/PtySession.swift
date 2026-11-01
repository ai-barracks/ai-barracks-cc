import Darwin
import Foundation
import PtyProtocol

/// TIOCSWINSZ is a function-like macro that Swift does not import.
private let terminalSetWindowSize: UInt = 0x8008_7467
private let killGrace: DispatchTimeInterval = .seconds(3)

/// One child process on a PTY owned by the daemon. Every member is touched on
/// the daemon's serial queue only; output is read by a `PtyReader` thread.
final class PtySession: @unchecked Sendable {
    let id: UUID
    let pid: pid_t
    let startedAt: Date
    private let masterFD: Int32
    private let queue: DispatchQueue
    private(set) var replay = Data()
    private(set) var exitInfo: ExitInfo?
    private var inputBacklog = Data()
    private var reader: PtyReader?
    private var writeSource: DispatchSourceWrite?
    private var exitSource: DispatchSourceProcess?
    private var masterOpen = true
    private var masterClosed = false
    private(set) var isOutputPaused = false
    /// Set by KILL: the record is dropped at exit instead of kept for attach.
    var discardOnExit = false
    private var onOutput: (Data) -> Void = { _ in }
    private var onExit: (ExitInfo) -> Void = { _ in }

    var isAlive: Bool { exitInfo == nil }

    var info: SessionInfo {
        SessionInfo(id: id, pid: pid, alive: isAlive, startedAt: startedAt.timeIntervalSince1970)
    }

    private init(id: UUID, pid: pid_t, masterFD: Int32, queue: DispatchQueue) {
        self.id = id
        self.pid = pid
        self.masterFD = masterFD
        self.queue = queue
        startedAt = Date()
    }

    /// Spawns `request` on a new PTY. Must run on `queue`: forks are
    /// serialized there, so every daemon fd already carries FD_CLOEXEC and
    /// no other session's master leaks into the child.
    static func spawn(id: UUID, request: CreateRequest, queue: DispatchQueue) -> PtySession? {
        guard request.executable.hasPrefix("/"), !request.argv.isEmpty else { return nil }
        guard let child = ChildLauncher(request: request).forkOnPTY() else { return nil }
        _ = fcntl(child.master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(child.master, F_SETFL, fcntl(child.master, F_GETFL) | O_NONBLOCK)
        return PtySession(id: id, pid: child.pid, masterFD: child.master, queue: queue)
    }

    func start(onOutput: @escaping (Data) -> Void, onExit: @escaping (ExitInfo) -> Void) {
        self.onOutput = onOutput
        self.onExit = onExit
        let reader = PtyReader(
            fd: masterFD, queue: queue,
            onData: { [weak self] data in self?.received(data) },
            onEnd: {}
        )
        self.reader = reader
        reader.start()

        let watcher = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        watcher.setEventHandler { [weak self] in self?.reapIfExited() }
        watcher.resume()
        exitSource = watcher
        // A child that died before the source was registered never fires it.
        queue.async { [weak self] in self?.reapIfExited() }
    }

    /// Queues input; a large paste is written as the PTY drains instead of
    /// being dropped on EAGAIN.
    func write(_ data: Data) {
        guard isAlive, masterOpen else { return }
        inputBacklog.append(data)
        flushInput()
    }

    func resize(_ request: ResizeRequest) {
        guard isAlive, masterOpen else { return }
        var size = winsize(ws_row: request.rows, ws_col: request.columns,
                           ws_xpixel: request.widthPixels, ws_ypixel: request.heightPixels)
        _ = withUnsafeMutablePointer(to: &size) { ioctl(masterFD, terminalSetWindowSize, $0) }
    }

    /// Back-pressure: while paused the PTY is not read, so the child blocks
    /// on write once the kernel buffer is full.
    func setOutputPaused(_ paused: Bool) {
        guard paused != isOutputPaused else { return }
        isOutputPaused = paused
        reader?.setPaused(paused)
    }

    /// Hangs up like a closing terminal (the kernel sends SIGHUP to the
    /// session), then SIGKILLs a child that ignores it.
    func terminate() {
        guard isAlive else { return }
        closeMaster {}
        queue.asyncAfter(deadline: .now() + killGrace) { [weak self] in
            guard let self, self.isAlive else { return }
            kill(self.pid, SIGKILL)
        }
    }

    // MARK: - Private

    private func received(_ data: Data) {
        remember(data)
        onOutput(data)
    }

    private func flushInput() {
        while !inputBacklog.isEmpty {
            let written = inputBacklog.withUnsafeBytes { raw in
                Darwin.write(masterFD, raw.baseAddress!, raw.count)
            }
            if written > 0 {
                inputBacklog.removeFirst(written)
            } else if written < 0 && errno == EINTR {
                continue
            } else if written < 0 && errno == EAGAIN {
                waitForWritable()
                return
            } else {
                inputBacklog.removeAll()
                return
            }
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func waitForWritable() {
        guard writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: queue)
        source.setEventHandler { [weak self] in self?.flushInput() }
        source.resume()
        writeSource = source
    }

    /// Keeps the last `replayLimit` bytes; compacts at 1.5x to amortize copies.
    private func remember(_ chunk: Data) {
        replay.append(chunk)
        if replay.count > PtyProtocol.replayLimit * 3 / 2 {
            replay = Data(replay.suffix(PtyProtocol.replayLimit))
        }
    }

    /// EXITED goes out only after the reader handed over its last output.
    private func reapIfExited() {
        guard isAlive else { return }
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return }
        let runtime = UInt64(max(Date().timeIntervalSince(startedAt), 0) * 1000)
        let info = ExitInfo(status: Self.exitCode(fromWaitStatus: status), runtimeMilliseconds: runtime)
        exitInfo = info
        exitSource?.cancel()
        exitSource = nil
        closeMaster { [weak self] in self?.onExit(info) }
    }

    /// Stops writing now; the fd is closed once the reader thread has left
    /// poll (closing it under a blocked poll could hit a reused fd).
    private func closeMaster(then completion: @escaping @Sendable () -> Void) {
        masterOpen = false
        writeSource?.cancel()
        writeSource = nil
        inputBacklog.removeAll()
        guard let reader else {
            closeFD()
            return completion()
        }
        reader.stop { [weak self] in
            self?.closeFD()
            completion()
        }
    }

    private func closeFD() {
        guard !masterClosed else { return }
        masterClosed = true
        close(masterFD)
    }

    /// WIFEXITED/WEXITSTATUS/WTERMSIG are macros Swift does not import.
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}

/// Prepares every C string before fork so the child only makes
/// async-signal-safe calls (sigprocmask, signal, chdir, execve, _exit).
private struct ChildLauncher {
    let request: CreateRequest

    func forkOnPTY() -> (pid: pid_t, master: Int32)? {
        let argv = request.argv.map { strdup($0) } + [nil]
        let environment = request.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let directory = strdup(request.workingDirectory)
        let path = strdup(request.executable)
        defer { (argv + environment + [directory, path]).forEach { free($0) } }
        var size = winsize(ws_row: request.rows, ws_col: request.columns, ws_xpixel: 0, ws_ypixel: 0)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var master: Int32 = -1
        let pid = argv.withUnsafeBufferPointer { argvBuffer in
            environment.withUnsafeBufferPointer { envBuffer in
                let child = forkpty(&master, nil, nil, &size)
                if child == 0 {
                    // Ignored signals survive exec (the daemon ignores
                    // SIGPIPE; whoever launched it may ignore more), so give
                    // the shell default dispositions and an empty mask.
                    sigprocmask(SIG_SETMASK, &emptyMask, nil)
                    signal(SIGPIPE, SIG_DFL)
                    signal(SIGHUP, SIG_DFL)
                    signal(SIGINT, SIG_DFL)
                    signal(SIGQUIT, SIG_DFL)
                    signal(SIGTERM, SIG_DFL)
                    signal(SIGCHLD, SIG_DFL)
                    signal(SIGTSTP, SIG_DFL)
                    signal(SIGTTIN, SIG_DFL)
                    signal(SIGTTOU, SIG_DFL)
                    _ = chdir(directory)
                    execve(path, argvBuffer.baseAddress, envBuffer.baseAddress)
                    _exit(127)
                }
                return child
            }
        }
        guard pid > 0, master >= 0 else { return nil }
        return (pid: pid, master: master)
    }
}
