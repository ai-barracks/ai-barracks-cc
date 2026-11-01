import Darwin
import Foundation

/// Frames over a connected stream socket (DispatchIO). `onFrame` and
/// `onClose` run on `queue`; `send` may be called from any thread and keeps
/// submission order. `onClose` fires exactly once.
public final class FramedConnection: @unchecked Sendable {
    /// A peer that stops reading must not grow the daemon without bound.
    public static let maxPendingWriteBytes = 64 * 1024 * 1024

    private let queue: DispatchQueue
    private let channel: DispatchIO
    private let lock = NSLock()
    private var decoder = FrameDecoder()
    private var pendingWriteBytes = 0
    private var isClosed = false
    private let onFrame: (Frame) -> Void
    private let onClose: () -> Void

    public init(fd: Int32, queue: DispatchQueue, onFrame: @escaping (Frame) -> Void, onClose: @escaping () -> Void) {
        self.queue = queue
        self.onFrame = onFrame
        self.onClose = onClose
        channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in Darwin.close(fd) }
        channel.setLimit(lowWater: 1)
    }

    public func start() {
        channel.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for frame in self.decoder.feed(Data(data)) { self.onFrame(frame) }
            }
            if done || error != 0 { self.close() }
        }
    }

    public func send(_ frame: Frame) {
        let bytes = frame.encoded()
        let overflow: Bool = lock.withLock {
            guard !isClosed else { return false }
            pendingWriteBytes += bytes.count
            return pendingWriteBytes > Self.maxPendingWriteBytes
        }
        if overflow {
            close()
            return
        }
        let payload = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: payload, queue: queue) { [weak self] done, _, error in
            guard let self, done else { return }
            self.lock.withLock { self.pendingWriteBytes -= bytes.count }
            if error != 0 { self.close() }
        }
    }

    public func close() {
        let first: Bool = lock.withLock {
            defer { isClosed = true }
            return !isClosed
        }
        guard first else { return }
        channel.close(flags: .stop)
        queue.async { self.onClose() }
    }
}

/// One-shot blocking request (CLI tools, app startup checks): sends `frame`
/// and returns the first reply of `expecting` type, or nil on timeout.
public enum FrameRequest {
    public static func send(
        _ frame: Frame, to socketPath: String, expecting: FrameType? = nil, timeout seconds: Double = 2
    ) -> Frame? {
        guard let fd = UnixSocket.connect(path: socketPath) else { return nil }
        defer { Darwin.close(fd) }
        UnixSocket.setReceiveTimeout(fd, seconds: seconds)
        let bytes = frame.encoded()
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        guard written == bytes.count else { return nil }
        guard let expecting else { return frame }
        var decoder = FrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return nil }
            if let reply = decoder.feed(Data(buffer[0..<count])).first(where: { $0.type == expecting }) {
                return reply
            }
        }
        return nil
    }
}
