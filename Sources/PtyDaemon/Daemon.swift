import Darwin
import Foundation
import PtyProtocol

/// Owns every PTY so shells and agents outlive the app (Herdr-style core
/// daemon). The app attaches over a Unix socket; output is fanned out to the
/// attached clients and the recent tail is replayed on attach. All state
/// lives on one serial queue.
final class Daemon: @unchecked Sendable {
    /// Exited sessions are kept (with their final output) for a later
    /// attach; beyond this count the oldest are dropped.
    private static let keptExitedSessions = 32
    /// Exited sessions whose child left processes running are kept (so a
    /// KILL can still end them) up to this many; past it the oldest are
    /// ended and dropped (r7).
    private static let keptLeftoverSessions = 64
    private static let idleExit: TimeInterval = 300
    private static let idleCheckInterval: DispatchTimeInterval = .seconds(30)
    private static let shutdownGrace: DispatchTimeInterval = .seconds(4)
    /// A session stops reading its PTY once a client is this far behind.
    private static let outputHighWater = 1024 * 1024

    private let queue = DispatchQueue(label: "aibcc.ptyd")
    private let socketPath: String
    private var sessions: [UUID: PtySession] = [:]
    private var clients: [ObjectIdentifier: Client] = [:]
    private var listener: DispatchSourceRead?
    private var idleTimer: DispatchSourceTimer?
    private var idleSince = Date()

    private final class Client {
        let connection: FramedConnection
        var attached: Set<UUID> = []
        init(connection: FramedConnection) { self.connection = connection }
    }

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Starts serving on an already bound, listening socket.
    func start(listeningFD fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(listener: fd) }
        source.resume()
        listener = source

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.idleCheckInterval, repeating: Self.idleCheckInterval)
        timer.setEventHandler { [weak self] in self?.exitIfIdle() }
        timer.resume()
        idleTimer = timer
        DaemonLog.write("listening at \(socketPath)")
    }

    // MARK: - Connections

    private func acceptPending(listener fd: Int32) {
        while let clientFD = UnixSocket.accept(listener: fd) {
            var client: Client?
            let connection = FramedConnection(
                fd: clientFD, queue: queue,
                onFrames: { [weak self] frames in
                    guard let self, let client else { return }
                    frames.forEach { self.handle($0, from: client) }
                },
                onClose: { [weak self] in
                    guard let self, let current = client else { return }
                    self.clients[ObjectIdentifier(current)] = nil
                    client = nil
                    self.updateFlowControl()
                    self.markIdleIfNeeded()
                }
            )
            connection.onWriteDrained = { [weak self] in self?.updateFlowControl() }
            let created = Client(connection: connection)
            client = created
            clients[ObjectIdentifier(created)] = created
            connection.start()
        }
    }

    private func handle(_ frame: Frame, from client: Client) {
        switch frame.type {
        case .create: create(frame, for: client)
        case .attach: attach(frame.session, for: client)
        case .input:
            if sessions[frame.session]?.write(frame.payload) == false {
                // Not a FAILURE: clients end a pane on those (Codex r6).
                client.connection.send(Frame(.inputRefused, session: frame.session,
                                             payload: Data("input refused: the program is not reading its input".utf8)))
            }
        case .resize:
            if let request = PtyProtocol.decode(ResizeRequest.self, from: frame.payload) {
                sessions[frame.session]?.resize(request)
            }
        case .detach:
            client.attached.remove(frame.session)
            updateFlowControl()
        case .hello:
            client.connection.send(Frame(.welcome, payload: PtyProtocol.json(Welcome(revision: PtyProtocol.revision))))
        case .list:
            let infos = sessions.values.map(\.info).sorted { $0.startedAt < $1.startedAt }
            client.connection.send(Frame(.sessions, payload: PtyProtocol.json(infos)))
        case .kill: kill(frame.session)
        case .shutdown: shutdown()
        default: fail(frame.session, "unexpected frame \(frame.type)", to: client)
        }
    }

    // MARK: - Sessions

    private func create(_ frame: Frame, for client: Client) {
        guard sessions[frame.session] == nil else { return fail(frame.session, "session exists", to: client) }
        guard let request = PtyProtocol.decode(CreateRequest.self, from: frame.payload),
              let session = PtySession.spawn(id: frame.session, request: request, queue: queue)
        else { return fail(frame.session, "spawn failed", to: client) }
        sessions[session.id] = session
        client.attached.insert(session.id)
        client.connection.send(Frame(.created, session: session.id, payload: PtyProtocol.json(session.info)))
        // The id, not the session: a closure holding the session it is
        // stored in kept every ended session alive (Codex r4).
        let id = session.id
        session.start(
            onOutput: { [weak self] data in
                self?.broadcast(Frame(.output, session: id, payload: data))
                self?.updateFlowControl()
            },
            onExit: { [weak self] info in self?.sessionExited(id, info) }
        )
        DaemonLog.write("created \(session.id) pid=\(session.pid) argv0=\(request.argv.first ?? "")")
    }

    /// ATTACHED, then the replay as one OUTPUT frame (possibly empty) so the
    /// client knows exactly which bytes are history, then EXITED if the
    /// process already ended. All on the queue, so no live output interleaves.
    private func attach(_ id: UUID, for client: Client) {
        guard let session = sessions[id] else { return fail(id, "unknown session", to: client) }
        client.attached.insert(id)
        client.connection.send(Frame(.attached, session: id, payload: PtyProtocol.json(session.info)))
        client.connection.send(Frame(.output, session: id, payload: session.replay))
        if let exit = session.exitInfo {
            client.connection.send(Frame(.exited, session: id, payload: PtyProtocol.json(exit)))
        }
    }

    private func kill(_ id: UUID) {
        guard let session = sessions[id] else { return }
        // An exited session still ends what its child left running.
        session.terminate()
        if !session.isAlive {
            sessions[id] = nil
        }
        // A killed session is never reattached: forget it once it exits.
        session.discardOnExit = true
    }

    private func sessionExited(_ id: UUID, _ info: ExitInfo) {
        broadcast(Frame(.exited, session: id, payload: PtyProtocol.json(info)))
        DaemonLog.write("exited \(id) status=\(info.status)")
        if sessions[id]?.discardOnExit == true { sessions[id] = nil }
        pruneExitedSessions()
        markIdleIfNeeded()
    }

    /// Drops the oldest exited records past the limit — not one whose child
    /// left processes running, which a KILL must still reach, unless those
    /// pass their own limit; those are ended first (r7: pruning forgot them).
    private func pruneExitedSessions() {
        let exited = sessions.values.filter { !$0.isAlive }.sorted { $0.startedAt < $1.startedAt }
        let holding = exited.filter(\.hasLeftovers)
        let held = Set(holding.map(\.id))
        for session in exited.filter({ !held.contains($0.id) }).dropLast(Self.keptExitedSessions) {
            sessions[session.id] = nil
        }
        for session in holding.dropLast(Self.keptLeftoverSessions) {
            session.terminate()
            sessions[session.id] = nil
        }
    }

    private func broadcast(_ frame: Frame) {
        for client in clients.values where client.attached.contains(frame.session) {
            client.connection.send(frame)
        }
    }

    /// Back-pressure: a session stops reading its PTY while any attached
    /// client is behind and resumes once every one has caught up, so a
    /// flood throttles the child like a terminal does instead of growing
    /// buffers. A session nobody is attached to keeps running (replay only).
    private func updateFlowControl() {
        for session in sessions.values where session.isAlive {
            let backlog = clients.values
                .filter { $0.attached.contains(session.id) }
                .map(\.connection.pendingWriteBytes)
                .max() ?? 0
            if session.isOutputPaused {
                if backlog <= FramedConnection.writeLowWater { session.setOutputPaused(false) }
            } else if backlog > Self.outputHighWater {
                session.setOutputPaused(true)
            }
        }
    }

    private func fail(_ id: UUID, _ message: String, to client: Client) {
        client.connection.send(Frame(.failure, session: id, payload: Data(message.utf8)))
    }

    // MARK: - Lifetime

    private func markIdleIfNeeded() {
        if clients.isEmpty && !sessions.values.contains(where: \.isAlive) { idleSince = Date() }
    }

    private func exitIfIdle() {
        guard clients.isEmpty, !sessions.values.contains(where: \.isAlive),
              Date().timeIntervalSince(idleSince) >= Self.idleExit
        else { return }
        DaemonLog.write("idle, exiting")
        stop(status: 0)
    }

    /// Hangs up every session, waits briefly for exits, then quits.
    private func shutdown() {
        DaemonLog.write("shutdown requested")
        // Exited sessions too: what their children left running ends (r7).
        sessions.values.forEach { $0.terminate() }
        queue.asyncAfter(deadline: .now() + Self.shutdownGrace) { [weak self] in self?.stop(status: 0) }
    }

    private func stop(status: Int32) {
        listener?.cancel()
        unlink(socketPath)
        exit(status)
    }
}

/// Timestamped lines on stderr, which the launcher points at a log file.
enum DaemonLog {
    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] ptyd: \(message)\n".utf8))
    }
}
