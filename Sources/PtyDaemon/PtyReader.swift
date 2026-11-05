import Darwin
import Foundation

/// Reads a PTY master on a dedicated thread (poll + non-blocking reads, like
/// Ghostty's IO thread). A dispatch read source paid its wake-up cost on
/// every 1 KiB the PTY hands out (14 MB/s measured); this thread reads at
/// PTY speed and batches whatever arrives while the daemon queue is busy.
/// `setPaused` stops reading so a slow client pushes back on the child,
/// exactly like a terminal that stops reading its PTY.
final class PtyReader: @unchecked Sendable {
    private static let readChunk = 65_536
    /// Hand a hot stream to the queue in bounded pieces.
    private static let maxBatch = 1024 * 1024
    /// Output read but not yet taken by the queue; past this the reader
    /// waits (a stream that never pauses must not grow it without bound).
    private static let maxPending = 8 * 1024 * 1024
    /// What a stop still reads from a child that keeps writing.
    private static let stopDrainLimit = 4 * 1024 * 1024
    /// While output streams (last hand-over within `streamWindow`), wait up
    /// to `coalesceWait` for more so a flood travels in large frames; output
    /// after a pause (an echo) is handed over at once.
    private static let streamWindowNanos: UInt64 = 2_000_000
    private static let coalesceWaitMillis: Int32 = 1

    private let fd: Int32
    private let queue: DispatchQueue
    private let onData: (Data) -> Void
    private let onEnd: () -> Void
    private let condition = NSCondition()
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    // Guarded by `condition`.
    private var pending = Data()
    private var flushScheduled = false
    private var paused = false
    private var stopping = false
    private var finished = false
    private var completions: [@Sendable () -> Void] = []
    /// Reader thread only.
    private var lastDelivery: UInt64 = 0

    /// `onData` and `onEnd` (EOF/EIO: the slave side closed) run on `queue`.
    init(fd: Int32, queue: DispatchQueue, onData: @escaping (Data) -> Void, onEnd: @escaping () -> Void) {
        self.fd = fd
        self.queue = queue
        self.onData = onData
        self.onEnd = onEnd
        var ends: [Int32] = [-1, -1]
        if pipe(&ends) == 0 {
            for end in ends {
                _ = fcntl(end, F_SETFD, FD_CLOEXEC)
                _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
            }
            wakeRead = ends[0]
            wakeWrite = ends[1]
        }
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "aibcc.ptyd.reader"
        thread.start()
    }

    func setPaused(_ value: Bool) {
        condition.withLock {
            paused = value
            condition.broadcast()
        }
        wake()
    }

    /// Reads what is left, stops, then runs `completion` on the queue after
    /// the last `onData`.
    func stop(then completion: @escaping @Sendable () -> Void) {
        let alreadyFinished: Bool = condition.withLock {
            guard !finished else { return true }
            stopping = true
            completions.append(completion)
            condition.broadcast()
            return false
        }
        if alreadyFinished { queue.async(execute: completion) } else { wake() }
    }

    // MARK: - Reader thread

    private func run() {
        var buffer = [UInt8](repeating: 0, count: Self.readChunk)
        var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
        var ended = false
        while !ended {
            let stop: Bool = condition.withLock {
                while paused && !stopping { condition.wait() }
                return stopping
            }
            if stop {
                ended = drain(&buffer, limit: Self.stopDrainLimit)
                break
            }
            let ready = poll(&fds, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if fds[1].revents != 0 { clearWake() }
            if fds[0].revents != 0 { ended = drain(&buffer) }
        }
        finish(ended: ended)
    }

    /// Reads until EAGAIN; true at EOF/EIO (the slave side is gone). A
    /// stream that never runs dry yields after each batch once paused or
    /// stopping (Codex r4: pause was only seen at EAGAIN); `limit` bounds a
    /// stop's final read.
    private func drain(_ buffer: inout [UInt8], limit: Int? = nil) -> Bool {
        var chunk = Data()
        var ended = false
        var total = 0
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                chunk.append(contentsOf: buffer[0..<count])
                total += count
                if chunk.count >= Self.maxBatch {
                    deliver(chunk)
                    chunk = Data()
                    if limit == nil, condition.withLock({ paused || stopping }) { break }
                }
                if let limit, total >= limit { break }
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && errno == EAGAIN && !chunk.isEmpty && isStreaming && moreArrives() {
                continue
            } else {
                ended = count == 0 || errno != EAGAIN
                break
            }
        }
        if !chunk.isEmpty { deliver(chunk) }
        return ended
    }

    private var isStreaming: Bool {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - lastDelivery < Self.streamWindowNanos
    }

    private func moreArrives() -> Bool {
        var probe = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&probe, 1, Self.coalesceWaitMillis) > 0
    }

    private func deliver(_ chunk: Data) {
        lastDelivery = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let schedule: Bool = condition.withLock {
            pending.append(chunk)
            defer { flushScheduled = true }
            return !flushScheduled
        }
        if schedule { queue.async { self.flush() } }
        condition.withLock {
            while pending.count > Self.maxPending && !stopping { condition.wait() }
        }
    }

    private func flush() {
        let data: Data = condition.withLock {
            defer {
                pending = Data()
                flushScheduled = false
                condition.broadcast()
            }
            return pending
        }
        if !data.isEmpty { onData(data) }
    }

    private func finish(ended: Bool) {
        let done: [@Sendable () -> Void] = condition.withLock {
            finished = true
            defer { completions = [] }
            return completions
        }
        condition.withLock {
            close(wakeRead)
            close(wakeWrite)
            wakeRead = -1
            wakeWrite = -1
        }
        // Enqueued after every flush this thread scheduled.
        queue.async { [self] in
            if ended { onEnd() }
            done.forEach { $0() }
        }
    }

    private func wake() {
        condition.withLock {
            guard wakeWrite >= 0 else { return }
            var byte: UInt8 = 1
            _ = write(wakeWrite, &byte, 1)
        }
    }

    private func clearWake() {
        var sink = [UInt8](repeating: 0, count: 64)
        while read(wakeRead, &sink, sink.count) > 0 {}
    }
}
