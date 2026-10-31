import CoreServices
import Foundation

/// FSEvents watcher for one directory tree. Calls `onChange` on the main
/// queue, coalesced by `latency`.
final class DirectoryWatcher: @unchecked Sendable {
    private let path: String
    private let latency: TimeInterval
    private let onChange: @MainActor @Sendable () -> Void
    private var stream: FSEventStreamRef?

    init(
        url: URL,
        latency: TimeInterval = AppConstants.Artifacts.watchLatency,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        path = url.path
        self.latency = latency
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            DirectoryWatcher.callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
        let handler = watcher.onChange
        MainActor.assumeIsolated { handler() }
    }
}
