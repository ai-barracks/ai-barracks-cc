import Darwin
import Foundation
import PtyProtocol

/// TIOCSWINSZ is a function-like macro that Swift does not import.
private let terminalSetWindowSize: UInt = 0x8008_7467
private let killGrace: DispatchTimeInterval = .seconds(3)
/// Input the child has not read yet; more is refused (Codex r4: unbounded).
private let maxInputBacklog = 8 * 1024 * 1024

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
    /// waitpid returned: the pid may be reused from here on.
    private var reaped = false
    /// Session members still running when the leader was reaped (pid and
    /// start time), so a later KILL ends exactly them and never a process
    /// that reused a number (Codex r6: leftovers of an exited leader were
    /// never ended).
    private var leftovers: [Member] = []
    /// Write sources not yet fully cancelled; the fd closes after them.
    private var liveWriteSources = 0
    private var closeWanted = false
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
    /// being dropped on EAGAIN. False when the child is not reading and the
    /// backlog is full: the input is refused, not buffered without bound.
    @discardableResult
    func write(_ data: Data) -> Bool {
        guard isAlive, masterOpen else { return true }
        guard inputBacklog.count + data.count <= maxInputBacklog else { return false }
        inputBacklog.append(data)
        flushInput()
        return true
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
    /// session), then SIGKILLs whatever of the session is left — the child
    /// and its descendants, background jobs included (Codex r4: a HUP-ignoring
    /// descendant outlived its closed pane). On a session whose child already
    /// exited it ends what the child left running (r6, r7).
    func terminate() {
        guard !reaped else { return endLeftovers() }
        guard isAlive else { return }
        closeMaster {}
        // Weak: the record may be gone by then (a killed session is dropped
        // at exit), and holding it would keep its buffers for the grace
        // (r7 smoke `leak`). Members still running hold the session id, so
        // the scan by id stays exact without the record.
        let sid = pid
        queue.asyncAfter(deadline: .now() + killGrace) { [weak self] in
            Self.stopAndKill(Self.members(of: sid), sid: sid)
            guard let self, !self.reaped else { return }
            kill(self.pid, SIGKILL)
        }
    }

    /// Session members still running after the leader exited.
    var hasLeftovers: Bool {
        refreshLeftovers()
        return !leftovers.isEmpty
    }

    /// While a member recorded earlier still runs, the session id is held
    /// and a scan finds exactly its members — those forked since included
    /// (r7: a snapshot taken at reap missed them). With none left the id may
    /// be reused, so nothing more is tracked.
    private func refreshLeftovers() {
        leftovers = leftovers.contains(where: \.isSameProcess) ? Self.members(of: pid) : []
    }

    private func endLeftovers() {
        refreshLeftovers()
        Self.stopAndKill(leftovers, sid: pid)
        leftovers = []
    }

    /// SIGSTOP stops the members forking; rescans (valid while a stopped
    /// member holds the session) catch what was forked before; then SIGKILL.
    private static func stopAndKill(_ known: [Member], sid: pid_t) {
        var members = known.filter(\.isSameProcess)
        for _ in 0 ..< 5 where !members.isEmpty {
            members.forEach { kill($0.pid, SIGSTOP) }
            let rescanned = Self.members(of: sid)
            let grown = Set(rescanned.map(\.pid)).subtracting(members.map(\.pid))
            members = rescanned
            if grown.isEmpty { break }
        }
        members.forEach { kill($0.pid, SIGKILL) }
    }

    struct Member {
        let pid: pid_t
        let started: UInt64

        /// Still the process recorded (same pid, same start time).
        var isSameProcess: Bool { PtySession.startTime(of: pid) == started }
    }

    static func members(of sid: pid_t) -> [Member] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(filled, 0))).compactMap { candidate in
            guard candidate > 1, candidate != sid, getsid(candidate) == sid, let started = startTime(of: candidate) else { return nil }
            return Member(pid: candidate, started: started)
        }
    }

    static func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
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
        liveWriteSources += 1
        // Strong: the fd is closed from here once the session is gone too
        // (Codex r6: a weak handler left it open). The cycle ends with the
        // cancellation, which releases the handlers.
        source.setCancelHandler { self.writeSourceEnded() }
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

    /// EXITED goes out only after the reader handed over its last output,
    /// and only then does the session count as exited: an ATTACH in
    /// between gets its replay and later the last OUTPUT, then EXITED
    /// (Codex r4: EXITED → OUTPUT → EXITED).
    private func reapIfExited() {
        guard !reaped else { return }
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return }
        reaped = true
        leftovers = Self.members(of: pid)
        let runtime = UInt64(max(Date().timeIntervalSince(startedAt), 0) * 1000)
        let info = ExitInfo(status: Self.exitCode(fromWaitStatus: status), runtimeMilliseconds: runtime)
        exitSource?.cancel()
        exitSource = nil
        closeMaster { [weak self] in
            guard let self else { return }
            self.exitInfo = info
            self.onExit(info)
            // Nothing more will come; drop the daemon's closures.
            self.onOutput = { _ in }
            self.onExit = { _ in }
        }
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
        reader.stop {
            self.closeFD()
            completion()
        }
    }

    /// Closes the master once no write source can still touch the number
    /// (Apple: release a source's fd only after its cancellation, Codex r4).
    private func closeFD() {
        closeWanted = true
        guard !masterClosed, liveWriteSources == 0 else { return }
        masterClosed = true
        close(masterFD)
    }

    private func writeSourceEnded() {
        liveWriteSources -= 1
        if closeWanted { closeFD() }
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
