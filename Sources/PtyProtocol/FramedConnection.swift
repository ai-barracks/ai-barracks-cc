import Darwin
import Foundation

/// Frames over a connected, non-blocking stream socket. `onFrames`, `onClose`
/// and `onWriteDrained` run on `queue`; `send`, `setReadingPaused` and
/// `pendingWriteBytes` are safe from any thread, and sends keep submission
/// order. `onClose` fires exactly once.
///
/// Flow control: `pendingWriteBytes` tells a producer that the peer is behind
/// (the daemon then stops reading the PTY), and pausing reads lets the kernel
/// socket buffer push back on the peer.
public final class FramedConnection: @unchecked Sendable {
    /// Hard cap for a peer that never reads; flow control keeps a healthy
    /// peer far below it.
    public static let maxPendingWriteBytes = 64 * 1024 * 1024
    /// `onWriteDrained` fires when a backlog falls to this level.
    public static let writeLowWater = 256 * 1024
    private static let readChunk = 256 * 1024

    private let fd: Int32
    private let queue: DispatchQueue
    private let lock = NSLock()
    // Guarded by `lock`.
    private var queued = Data()
    private var pendingCount = 0
    private var flushScheduled = false
    private var isClosed = false
    private var closesWhenDrained = false
    private var readPaused = false
    // Queue-only.
    private var writing = Data()
    private var writeOffset = 0
    private var decoder = FrameDecoder()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var readSuspended = false
    /// After this the fd number may already belong to another file: no
    /// queued read or write may touch it.
    private var fdClosed = false
    private var readBuffer = [UInt8](repeating: 0, count: FramedConnection.readChunk)
    /// Sources not yet fully cancelled: the fd is released after them
    /// (Apple's rule; Codex r4: it was closed right after cancel()).
    private var liveSources = 0
    private var closeRequested = false
    private var released = false
    // Guarded by `lock`: the backlog went above the low-water mark since the
    // last drain notice (with or without an EAGAIN on the way — Codex r4).
    private var aboveLowWater = false

    private let onFrames: ([Frame]) -> Void
    private let onClose: () -> Void
    /// Set before `start()`.
    public var onWriteDrained: (() -> Void)?

    /// `onFrames` receives every complete frame of one socket read at once,
    /// so a consumer can merge consecutive output.
    public init(fd: Int32, queue: DispatchQueue, onFrames: @escaping ([Frame]) -> Void, onClose: @escaping () -> Void) {
        self.fd = fd
        self.queue = queue
        self.onFrames = onFrames
        self.onClose = onClose
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    public func start() {
        queue.async { [self] in
            guard !lock.withLock({ isClosed }) else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            liveSources += 1
            source.setCancelHandler { [self] in sourceEnded() }
            source.resume()
            readSource = source
            applyReadPause()
        }
    }

    public var pendingWriteBytes: Int { lock.withLock { pendingCount } }

    public func send(_ frame: Frame) {
        let bytes = frame.encoded()
        let (schedule, overflow): (Bool, Bool) = lock.withLock {
            guard !isClosed else { return (false, false) }
            queued.append(bytes)
            pendingCount += bytes.count
            if pendingCount > Self.writeLowWater { aboveLowWater = true }
            defer { flushScheduled = true }
            return (!flushScheduled, pendingCount > Self.maxPendingWriteBytes)
        }
        if overflow {
            close()
        } else if schedule {
            queue.async { self.flushWrites() }
        }
    }

    /// Stops (or resumes) reading so the peer's writes back up in the kernel.
    public func setReadingPaused(_ paused: Bool) {
        lock.withLock { readPaused = paused }
        queue.async { self.applyReadPause() }
    }

    /// Closes once every frame sent so far is written.
    public func closeWhenDrained() {
        let drained: Bool = lock.withLock {
            closesWhenDrained = true
            return pendingCount == 0
        }
        if drained { close() }
    }

    public func close() {
        let first: Bool = lock.withLock {
            defer { isClosed = true }
            return !isClosed
        }
        guard first else { return }
        queue.async { [self] in
            fdClosed = true
            // A suspended source must be resumed before it is cancelled.
            if readSuspended { readSource?.resume() }
            readSource?.cancel()
            writeSource?.cancel()
            readSource = nil
            writeSource = nil
            closeRequested = true
            releaseIfQuiescent()
        }
    }

    private func sourceEnded() {
        liveSources -= 1
        releaseIfQuiescent()
    }

    /// The fd closes (and `onClose` fires) once, after every source's
    /// cancellation has completed.
    private func releaseIfQuiescent() {
        guard closeRequested, liveSources == 0, !released else { return }
        released = true
        Darwin.close(fd)
        onClose()
    }

    // MARK: - Queue

    private func applyReadPause() {
        guard !fdClosed, let readSource, !lock.withLock({ isClosed }) else { return }
        let paused = lock.withLock { readPaused }
        guard paused != readSuspended else { return }
        readSuspended = paused
        if paused { readSource.suspend() } else { readSource.resume() }
    }

    private func readAvailable() {
        while !fdClosed, !lock.withLock({ readPaused || isClosed }) {
            let count = Darwin.read(fd, &readBuffer, readBuffer.count)
            if count > 0 {
                let frames = decoder.feed(Data(readBuffer[0..<count]))
                if !frames.isEmpty { onFrames(frames) }
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                if count == 0 || errno != EAGAIN { close() }
                return
            }
        }
    }

    private func flushWrites() {
        guard !fdClosed else { return }
        if writeOffset >= writing.count {
            writing = lock.withLock {
                defer { queued = Data() }
                return queued
            }
            writeOffset = 0
        }
        let result = writeBuffered()
        let (closeNow, more, drained): (Bool, Bool, Bool) = lock.withLock {
            pendingCount -= result.written
            let idle = pendingCount == 0
            if idle { flushScheduled = false }
            let drained = aboveLowWater && pendingCount <= Self.writeLowWater
            if drained { aboveLowWater = false }
            return (idle && closesWhenDrained, !idle && writeOffset >= writing.count, drained)
        }
        if result.failed || closeNow { return close() }
        if result.blocked {
            waitForWritable()
        } else {
            writeSource?.cancel()
            writeSource = nil
            // Frames queued while this batch was written.
            if more { queue.async { self.flushWrites() } }
        }
        if drained { onWriteDrained?() }
    }

    private func writeBuffered() -> (written: Int, blocked: Bool, failed: Bool) {
        var written = 0
        var blocked = false
        var failed = false
        writing.withUnsafeBytes { raw in
            while writeOffset < raw.count {
                let result = Darwin.write(fd, raw.baseAddress! + writeOffset, raw.count - writeOffset)
                if result > 0 {
                    writeOffset += result
                    written += result
                } else if result < 0 && errno == EINTR {
                    continue
                } else {
                    blocked = result < 0 && errno == EAGAIN
                    failed = !blocked
                    return
                }
            }
        }
        return (written, blocked, failed)
    }

    private func waitForWritable() {
        guard writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.flushWrites() }
        liveSources += 1
        source.setCancelHandler { [self] in sourceEnded() }
        source.resume()
        writeSource = source
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
