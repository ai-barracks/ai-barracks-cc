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
    private static let idleExit: TimeInterval = 300
    private static let idleCheckInterval: DispatchTimeInterval = .seconds(30)
    private static let shutdownGrace: DispatchTimeInterval = .seconds(4)

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
                onFrame: { [weak self] frame in
                    guard let self, let client else { return }
                    self.handle(frame, from: client)
                },
                onClose: { [weak self] in
                    guard let self, let current = client else { return }
                    self.clients[ObjectIdentifier(current)] = nil
                    client = nil
                    self.markIdleIfNeeded()
                }
            )
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
        case .input: sessions[frame.session]?.write(frame.payload)
        case .resize:
            if let request = PtyProtocol.decode(ResizeRequest.self, from: frame.payload) {
                sessions[frame.session]?.resize(request)
            }
        case .detach: client.attached.remove(frame.session)
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
        session.start(
            onOutput: { [weak self] data in self?.broadcast(Frame(.output, session: session.id, payload: data)) },
            onExit: { [weak self] info in self?.sessionExited(session.id, info) }
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
        if session.isAlive {
            session.terminate()
        } else {
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

    private func pruneExitedSessions() {
        let exited = sessions.values.filter { !$0.isAlive }.sorted { $0.startedAt < $1.startedAt }
        for session in exited.dropLast(Self.keptExitedSessions) {
            sessions[session.id] = nil
        }
    }

    private func broadcast(_ frame: Frame) {
        for client in clients.values where client.attached.contains(frame.session) {
            client.connection.send(frame)
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
        sessions.values.filter(\.isAlive).forEach { $0.terminate() }
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
