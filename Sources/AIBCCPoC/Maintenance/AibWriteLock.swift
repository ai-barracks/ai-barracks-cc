import Darwin
import Foundation

/// One file lock around every aib write the app starts — run in-process
/// (AibWriteQueue) or typed into a pane (Sync All, ⌘K aib sync) — because
/// aib's registry update takes none (Codex r6: pane syncs ran beside the
/// queue). lockf(1) and flock(2) share the same BSD lock.
enum AibWriteLock {
    static var path: String {
        ((AppConstants.Daemon.supportDirectory as NSString).expandingTildeInPath as NSString)
            .appendingPathComponent(AppConstants.Maintenance.aibWriteLockName)
    }

    /// `command` for a shell, run while the lock is held.
    static func wrap(_ command: String) -> String {
        "/usr/bin/lockf -k \(AgentLauncher.shellQuote(path)) /bin/sh -c \(AgentLauncher.shellQuote(command))"
    }

    /// Runs `operation` holding the lock, after any pane that holds it.
    static func hold<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
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
