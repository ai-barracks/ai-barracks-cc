import Foundation

/// Wire protocol between the app (UI) and AIBCCPtyDaemon (PTY owner).
/// Frame = [type: UInt8][session: 16-byte UUID][length: UInt32 BE][payload].
/// Control payloads are JSON; INPUT/OUTPUT payloads are raw terminal bytes.
public enum FrameType: UInt8, Sendable {
    // client → daemon
    case create = 1, attach, input, resize, detach, list, kill, shutdown
    // daemon → client
    case created = 101, attached, output, exited, sessions, failure
    /// The child is not reading and its input backlog is full: this INPUT
    /// was dropped; the session itself is fine (older clients skip it).
    case inputRefused
}

public struct Frame: Sendable, Equatable {
    public let type: FrameType
    public let session: UUID
    public let payload: Data

    public init(_ type: FrameType, session: UUID = PtyProtocol.noSession, payload: Data = Data()) {
        self.type = type
        self.session = session
        self.payload = payload
    }

    public func encoded() -> Data {
        var data = Data([type.rawValue])
        withUnsafeBytes(of: session.uuid) { data.append(contentsOf: $0) }
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }
}

/// Incremental decoder: feed socket bytes, take complete frames. Parses by
/// offset and compacts once per feed (no per-frame buffer copies).
public struct FrameDecoder: Sendable {
    private var buffer = Data()
    private static let headerSize = 1 + 16 + 4

    public init() {}

    public mutating func feed(_ data: Data) -> [Frame] {
        buffer.append(data)
        var frames: [Frame] = []
        var offset = buffer.startIndex
        while let (frame, next) = parse(at: offset) {
            if let frame { frames.append(frame) }
            offset = next
        }
        if offset > buffer.startIndex {
            buffer = Data(buffer[offset...])
        }
        return frames
    }

    /// Returns the frame at `offset` (nil frame for an unknown type, which is
    /// skipped) and the offset after it, or nil when incomplete.
    private func parse(at offset: Data.Index) -> (Frame?, Data.Index)? {
        guard buffer.endIndex - offset >= Self.headerSize else { return nil }
        let header = [UInt8](buffer[offset..<(offset + Self.headerSize)])
        let length = header[17...20].reduce(0) { ($0 << 8) | Int($1) }
        let payloadStart = offset + Self.headerSize
        guard buffer.endIndex - payloadStart >= length else { return nil }
        let next = payloadStart + length
        guard let type = FrameType(rawValue: header[0]) else { return (nil, next) }
        let uuid = UUID(uuid: (header[1], header[2], header[3], header[4], header[5], header[6], header[7], header[8],
                               header[9], header[10], header[11], header[12], header[13], header[14], header[15], header[16]))
        return (Frame(type, session: uuid, payload: Data(buffer[payloadStart..<next])), next)
    }
}

/// `executable` must be absolute (the daemon does no PATH lookup);
/// `argv[0]` may differ, e.g. "-zsh" for a login shell. `environment` is
/// the child's complete environment — the long-lived daemon's own one never
/// leaks into it.
public struct CreateRequest: Codable, Sendable {
    public let executable: String
    public let argv: [String]
    public let workingDirectory: String
    public let environment: [String: String]
    public let columns: UInt16
    public let rows: UInt16

    public init(
        executable: String, argv: [String], workingDirectory: String,
        environment: [String: String], columns: UInt16, rows: UInt16
    ) {
        self.executable = executable
        self.argv = argv
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.columns = columns
        self.rows = rows
    }
}

public struct ResizeRequest: Codable, Sendable {
    public let columns: UInt16
    public let rows: UInt16
    public let widthPixels: UInt16
    public let heightPixels: UInt16

    public init(columns: UInt16, rows: UInt16, widthPixels: UInt16, heightPixels: UInt16) {
        self.columns = columns
        self.rows = rows
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
    }
}

public struct SessionInfo: Codable, Sendable, Equatable {
    public let id: UUID
    public let pid: Int32
    public let alive: Bool
    public let startedAt: Double

    public init(id: UUID, pid: Int32, alive: Bool, startedAt: Double) {
        self.id = id
        self.pid = pid
        self.alive = alive
        self.startedAt = startedAt
    }
}

public struct ExitInfo: Codable, Sendable {
    public let status: Int32
    public let runtimeMilliseconds: UInt64

    public init(status: Int32, runtimeMilliseconds: UInt64) {
        self.status = status
        self.runtimeMilliseconds = runtimeMilliseconds
    }
}

public enum PtyProtocol {
    public static let noSession = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    /// Recent raw output kept per session and replayed on attach. Kept
    /// below InMemoryTerminalSession's 1 MiB pre-attach buffer, which drops
    /// the oldest bytes past its cap.
    public static let replayLimit = 960 * 1024
    /// Bumped on any incompatible frame change; part of the socket name,
    /// so an updated app never talks to an older daemon (whose sessions
    /// stay reachable to the older app).
    public static let version = 1
    public static let defaultSocketName = "ptyd-v\(version).sock"

    public static func json<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
