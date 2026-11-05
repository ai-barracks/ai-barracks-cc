import Darwin
import Foundation

/// One file lock around every aib write the app starts — run in-process
/// (AibWriteQueue) or typed into a pane (Sync All, ⌘K aib sync) — because
/// aib's registry update takes none (Codex r6: pane syncs ran beside the
/// queue). lockf(1) and flock(2) share the same BSD lock.
enum AibWriteLock {
    /// One lock per registry the writes go to, in a folder both app
    /// variants share (r7: the development and release apps each locked
    /// their own folder while writing the same ~/.aib/barracks.json).
    static var path: String {
        path(selfTest: AppSettings.isSelfTest, registry: AppConstants.Paths.barracksRegistry)
    }

    static func path(selfTest: Bool, registry: String) -> String {
        let base = selfTest ? AppConstants.Daemon.supportDirectory : AppConstants.Maintenance.sharedSupportDirectory
        let target = URL(fileURLWithPath: (registry as NSString).expandingTildeInPath).standardizedFileURL.path
        return ((base as NSString).expandingTildeInPath as NSString)
            .appendingPathComponent(AppConstants.Maintenance.aibWriteLockPrefix + digest(target) + ".lock")
    }

    /// `command` for a shell, run while the lock is held.
    static func wrap(_ command: String) -> String {
        let lock = prepare()
        return "/usr/bin/lockf -k \(AgentLauncher.shellQuote(lock)) /bin/sh -c \(AgentLauncher.shellQuote(command))"
    }

    /// The lock's folder exists for either path (r7: only `hold` made it, so
    /// a first pane apply could fail).
    @discardableResult
    static func prepare() -> String {
        let lock = path
        try? FileManager.default.createDirectory(atPath: (lock as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return lock
    }

    /// FNV-1a: a short stable name for a path (not security relevant).
    private static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }

    /// Runs `operation` holding the lock, after any pane that holds it.
    static func hold<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let path = prepare()
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return await operation() }
        // Closing the descriptor releases the lock.
        defer { close(fd) }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            try? await Task.sleep(for: AppConstants.Maintenance.aibWriteLockPoll)
        }
        return await operation()
    }
}
