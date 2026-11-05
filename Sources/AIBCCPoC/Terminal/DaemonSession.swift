import Foundation
import GhosttyTerminal
import PtyProtocol

/// One pane's link to a daemon-owned PTY. Bytes flow straight between the
/// socket queue and libghostty's in-memory session (both thread-safe); only
/// lifecycle events hop to the main actor.
final class DaemonSession: @unchecked Sendable {
    enum Event: Sendable {
        case started(pid: pid_t, alive: Bool)
        /// The child is gone (EXITED or the daemon connection closed).
        case exited(status: Int32)
        /// Everything up to the end has been parsed. `final`: the daemon
        /// reported the exit (not just a lost connection, r7).
        case outputComplete(final: Bool)
        case failed(String)
        /// The program is not reading: some input was dropped. The session
        /// goes on.
        case inputRefused(String)
    }

    /// `.create` spawns on the first viewport report so the child starts
    /// at the real grid size, like Ghostty's exec backend does.
    enum Start: Sendable {
        case create(CreateRequest)
        case attach
    }

    let id: UUID
    private(set) var terminal: InMemoryTerminalSession!
    private let queue = DispatchQueue(label: "aibcc.ptyd.client")
    private let lock = NSLock()
    /// Set once in init; sending on a closed connection is a no-op.
    private var connection: FramedConnection!
    private var pendingCreate: CreateRequest?
    private var awaitingReplay = false
    private var finished = false
    private var killed = false
    private let onEvent: @Sendable (Event) -> Void

    init?(id: UUID, socketPath: String, start: Start, onEvent: @escaping @Sendable (Event) -> Void) {
        self.id = id
        self.onEvent = onEvent
        terminal = InMemoryTerminalSession(
            write: { [weak self] data in self?.sendInput(data) },
            resize: { [weak self] viewport in self?.sendResize(viewport) }
        )
        guard let fd = UnixSocket.connect(path: socketPath) else { return nil }
        // Flags are set before the connection starts delivering frames.
        switch start {
        case let .create(request):
            pendingCreate = request
        case .attach:
            awaitingReplay = true
        }
        let connection = FramedConnection(
            fd: fd, queue: queue,
            onFrames: { [weak self] frames in self?.handle(frames) },
            onClose: { [weak self] in self?.connectionClosed() }
        )
        self.connection = connection
        // Ghostty parsing behind → stop reading the socket → the daemon's
        // send backlog grows → it stops reading the PTY → the child blocks.
        terminal.setOutputBacklogHandler(
            highWater: AppConstants.Daemon.parseBacklogHighWater,
            lowWater: AppConstants.Daemon.parseBacklogLowWater
        ) { [weak connection] backlogged in connection?.setReadingPaused(backlogged) }
        connection.start()
        if case .attach = start { connection.send(Frame(.attach, session: id)) }
    }

    /// Ends the session for good (pane replaced or closed by the user).
    /// Idempotent: the workspace calls it on removal, deinit again.
    func kill() {
        guard lock.withLock({ () -> Bool in
            defer { killed = true }
            return !killed
        }) else { return }
        connection?.send(Frame(.kill, session: id))
        connection?.closeWhenDrained()
    }

    // MARK: - Terminal callbacks (any thread)

    private func sendInput(_ data: Data) {
        connection?.send(Frame(.input, session: id, payload: data))
    }

    private func sendResize(_ viewport: InMemoryTerminalViewport) {
        queue.async { [self] in
            if let template = pendingCreate {
                pendingCreate = nil
                let request = CreateRequest(
                    executable: template.executable, argv: template.argv,
                    workingDirectory: template.workingDirectory, environment: template.environment,
                    columns: Self.clamp(viewport.columns), rows: Self.clamp(viewport.rows)
                )
                connection?.send(Frame(.create, session: id, payload: PtyProtocol.json(request)))
            }
            let resize = ResizeRequest(
                columns: Self.clamp(viewport.columns), rows: Self.clamp(viewport.rows),
                widthPixels: Self.clamp(viewport.widthPixels), heightPixels: Self.clamp(viewport.heightPixels)
            )
            connection?.send(Frame(.resize, session: id, payload: PtyProtocol.json(resize)))
        }
    }

    // MARK: - Daemon frames (queue)

    /// Consecutive output frames go to the terminal as one `receive`: each
    /// call is a hop onto libghostty's parse queue.
    private func handle(_ frames: [Frame]) {
        var output = Data()
        for frame in frames where frame.session == id {
            if frame.type == .output && !awaitingReplay {
                output.append(frame.payload)
                continue
            }
            if !output.isEmpty {
                terminal.receive(output)
                output = Data()
            }
            handle(frame)
        }
        if !output.isEmpty { terminal.receive(output) }
    }

    private func handle(_ frame: Frame) {
        switch frame.type {
        case .created, .attached:
            guard let info = PtyProtocol.decode(SessionInfo.self, from: frame.payload) else { return }
            onEvent(.started(pid: info.pid, alive: info.alive))
        case .output:
            // The first OUTPUT after ATTACH is the replay. The program
            // answered its queries (DA, DSR, OSC colors) once already, so the
            // terminal parses it with replies suppressed; live output behind
            // it is answered (Codex r4: a muted-input window leaked replay
            // answers and swallowed live ones).
            if awaitingReplay {
                awaitingReplay = false
                terminal.receiveReplay(frame.payload)
            } else {
                terminal.receive(frame.payload)
            }
        case .exited:
            let exit = PtyProtocol.decode(ExitInfo.self, from: frame.payload)
            finish(status: exit?.status ?? -1, runtime: exit?.runtimeMilliseconds ?? 0, final: true)
        case .failure:
            onEvent(Self.event(forFailure: String(decoding: frame.payload, as: UTF8.self)))
        case .inputRefused:
            onEvent(.inputRefused(String(decoding: frame.payload, as: UTF8.self)))
        default:
            break
        }
    }

    private func connectionClosed() {
        finish(status: -1, runtime: 0, final: false)
    }

    private func finish(status: Int32, runtime: UInt64, final: Bool) {
        guard !finished else { return }
        finished = true
        terminal.finish(exitCode: UInt32(bitPattern: status), runtimeMilliseconds: runtime)
        onEvent(.exited(status: status))
        // The archive reads the screen: only once the last output is parsed
        // (Codex r4: archived at PID exit, before the final output arrived).
        let onEvent = onEvent
        terminal.enqueueMarker { onEvent(.outputComplete(final: final)) }
    }

    /// Revision-1 daemons (2.0.0-beta.1) report refused input as a FAILURE;
    /// it is not the session's end (r7, until such a daemon is replaced).
    static func event(forFailure message: String) -> Event {
        message.hasPrefix(AppConstants.Daemon.legacyInputRefusal) ? .inputRefused(message) : .failed(message)
    }

    private static func clamp<T: BinaryInteger>(_ value: T) -> UInt16 {
        UInt16(clamping: value)
    }
}
