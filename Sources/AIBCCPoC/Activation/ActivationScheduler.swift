import Darwin
import Foundation

/// v1 ActivationScheduler/Core: owns the schedule file through an
/// exclusive flock (a second app instance — v1 or v2 — cannot schedule or
/// save), claims a slot on disk before any child starts, and never retries.
final class ActivationScheduler: @unchecked Sendable {
    struct View: Equatable {
        var config = ActivationConfig()
        var available = false
        var error: String?
        var nextSlot: Date?
        var history: [ActivationRun] = []
    }

    typealias BinaryFinder = @Sendable (ActivationProvider) -> URL?
    typealias Activate = @Sendable (ActivationProvider, URL, @escaping @Sendable () -> Bool) -> Result<Void, ActivationFailure>

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "aibcc.activation")
    private let directory: URL
    private var fileURL: URL?
    /// Another app holds the lock: show its setting and take over once it quits.
    private var waitingForLock = false
    private let findBinary: BinaryFinder
    private let activate: Activate
    private let clock: @Sendable () -> Date
    private var document = ActivationDocument()
    private var error: String?
    private var lockFD: Int32 = -1
    private var generation: UInt64 = 0
    private var armedAfter: Int64
    private var shutdown = false
    private var timer: DispatchSourceTimer?

    init(directory: URL,
         findBinary: @escaping BinaryFinder = { ActivationRunner.findBinary($0.binaryName) },
         activate: @escaping Activate = { ActivationRunner.activate($0, binary: $1, cancelled: $2) },
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.findBinary = findBinary
        self.activate = activate
        self.clock = clock
        armedAfter = Int64(clock().timeIntervalSince1970)
        acquire()
    }

    deinit {
        if lockFD >= 0 { close(lockFD) }
    }

    static let lockedMessage = "다른 CommandCenter(v1 포함)가 예약을 맡고 있습니다 — 그 앱이 끝나면 이 앱이 이어받습니다"

    /// Takes the lock and the document, or shows the owner's setting read-only.
    private func acquire() {
        let opened = Self.open(directory)
        lock.withLock {
            switch opened {
            case let .success((fd, loaded)):
                lockFD = fd
                document = loaded
                fileURL = directory.appendingPathComponent("activation.json")
                error = nil
                waitingForLock = false
                // Taking over inside a slot waits for the next one.
                armedAfter = Int64(clock().timeIntervalSince1970)
                if !persist(loaded) { error = error ?? "예약 파일을 저장하지 못했습니다" }
            case let .failure(failure):
                fileURL = nil
                error = failure.message
                waitingForLock = failure.message == Self.lockedMessage
                if let data = try? Data(contentsOf: directory.appendingPathComponent("activation.json")),
                   case let .success(shown) = ActivationSchedule.decode(data) {
                    document = shown
                }
            }
        }
    }

    /// Gives the lock up (owner side of a takeover; self-tests).
    func release() {
        stop()
        lock.withLock {
            if lockFD >= 0 { close(lockFD) }
            lockFD = -1
            fileURL = nil
        }
    }

    /// Polls every 5 s like v1; a slot is claimed at most once.
    func start() {
        let runnable = lock.withLock { (fileURL != nil || waitingForLock) && timer == nil }
        guard runnable else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .seconds(5))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    func stop() {
        lock.withLock {
            shutdown = true
            generation += 1
        }
        timer?.cancel()
        timer = nil
        BoundedProcess.kill(tag: BoundedProcess.activationTag)
    }

    /// One poll (the timer's handler; self-tests call it with a fake clock).
    func tick() {
        if lock.withLock({ waitingForLock && !shutdown }) { acquire() }
        guard let slot = ActivationSchedule.slot(at: clock()) else { return }
        let started = lock.withLock { generation }
        for provider in claim(slot) {
            let result: Result<Void, ActivationFailure>
            if isCancelled(started) {
                result = .failure("Cancelled after settings changed")
            } else if !mark(provider, slot, status: "running", detail: nil) {
                result = .failure("Schedule storage failed before dispatch")
            } else if let binary = findBinary(provider) {
                result = activate(provider, binary) { [weak self] in self?.isCancelled(started) ?? true }
            } else {
                result = .failure("\(provider.binaryName) CLI not found in GUI PATH")
            }
            switch result {
            case .success: mark(provider, slot, status: "success", detail: "One minimal request completed")
            case let .failure(failure): mark(provider, slot, status: "failed", detail: failure.message)
            }
        }
    }

    func view() -> View {
        lock.withLock {
            View(config: document.config, available: error == nil, error: error,
                 nextSlot: document.config.enabled && error == nil ? ActivationSchedule.nextSlot(after: clock()) : nil,
                 history: document.history)
        }
    }

    /// v1 save: OFF always takes effect (cancels in-flight work); ON means
    /// the next future slot, never "run now".
    func save(_ config: ActivationConfig) -> Result<View, ActivationFailure> {
        guard !config.enabled || config.claude || config.codex else { return .failure("CLI를 하나 이상 고르세요") }
        let outcome: Result<Void, ActivationFailure> = lock.withLock {
            if !config.enabled {
                document.config = config
                generation += 1
            }
            guard fileURL != nil else { return .failure("예약을 쓸 수 없습니다: \(error ?? "저장소 없음")") }
            if config.enabled, let error { return .failure("예약을 쓸 수 없습니다: \(error)") }
            var updated = document
            updated.config = config
            guard persist(updated) else { return .failure(ActivationFailure(error ?? "예약 파일을 저장하지 못했습니다")) }
            document = updated
            armedAfter = Int64(clock().timeIntervalSince1970)
            generation += 1
            return .success(())
        }
        // OFF stops a request in flight now, not at the next poll (v1 cancel_work).
        if !config.enabled { BoundedProcess.kill(tag: BoundedProcess.activationTag) }
        return outcome.map { _ in view() }
    }

    // MARK: - Claims (persisted before any subprocess)

    private func claim(_ slot: Date) -> [ActivationProvider] {
        lock.withLock {
            let stamp = Int64(slot.timeIntervalSince1970)
            guard !shutdown, error == nil, document.config.enabled, stamp > armedAfter else { return [] }
            let providers = [ActivationProvider.claude, .codex].filter { provider in
                document.config.selected(provider) && (document.lastClaimed[provider].map { stamp > $0 } ?? true)
            }
            guard !providers.isEmpty else { return [] }
            var updated = document
            for provider in providers {
                updated.lastClaimed[provider] = stamp
                updated.history.insert(ActivationRun(provider: provider, slot: ActivationSchedule.format(slot), status: "pending",
                                                     detail: "Claimed; no automatic retry"), at: 0)
            }
            updated.history = Array(updated.history.prefix(ActivationSchedule.historyLimit))
            guard persist(updated) else { return [] }
            document = updated
            return providers
        }
    }

    @discardableResult
    private func mark(_ provider: ActivationProvider, _ slot: Date, status: String, detail: String?) -> Bool {
        lock.withLock {
            let label = ActivationSchedule.format(slot)
            var updated = document
            if let index = updated.history.firstIndex(where: { $0.provider == provider && $0.slot == label }) {
                updated.history[index].status = status
                if let detail { updated.history[index].detail = detail }
            }
            guard persist(updated) else { return false }
            document = updated
            return true
        }
    }

    private func isCancelled(_ started: UInt64) -> Bool {
        BoundedProcess.isShuttingDown || lock.withLock { shutdown || generation != started || error != nil }
    }

    // MARK: - Storage

    /// Owner-only temp file, fsync, rename, fsync the directory. Caller holds the lock.
    private func persist(_ document: ActivationDocument) -> Bool {
        guard let fileURL, let data = ActivationSchedule.encode(document) else { return false }
        let temp = fileURL.deletingLastPathComponent().appendingPathComponent(".activation-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return fail("예약 파일을 쓸 수 없습니다") }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) } == data.count
        let synced = fsync(fd) == 0
        close(fd)
        guard written, synced, rename(temp.path, fileURL.path) == 0 else {
            unlink(temp.path)
            return fail("예약 파일을 저장하지 못했습니다")
        }
        let directory = Darwin.open(fileURL.deletingLastPathComponent().path, O_RDONLY)
        if directory >= 0 {
            fsync(directory)
            close(directory)
        }
        return true
    }

    private func fail(_ message: String) -> Bool {
        error = message
        return false
    }

    /// The exclusive lock, then the document (v1 load).
    private static func open(_ directory: URL) -> Result<(Int32, ActivationDocument), ActivationFailure> {
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return .failure("예약 저장소를 쓸 수 없습니다")
        }
        let fd = Darwin.open(directory.appendingPathComponent("activation.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return .failure("예약 잠금 파일을 열 수 없습니다") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return .failure(ActivationFailure(lockedMessage))
        }
        let file = directory.appendingPathComponent("activation.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else {
            return .success((fd, ActivationDocument()))
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular, let data = try? Data(contentsOf: file) else {
            close(fd)
            return .failure("예약 파일이 잘못되어 예약을 껐습니다")
        }
        switch ActivationSchedule.decode(data) {
        case let .success(document): return .success((fd, document))
        case let .failure(failure):
            close(fd)
            return .failure(failure)
        }
    }
}
