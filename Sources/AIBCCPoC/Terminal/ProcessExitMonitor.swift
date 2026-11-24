import Foundation

/// Watches one process for exit with kqueue (`DispatchSource` process
/// source). Ghostty keeps a surface open after its child exits (it emits
/// SHOW_CHILD_EXITED, which libghostty-spm does not forward), so the app
/// detects the exit itself and keeps the pane's final output visible.
final class ProcessExitMonitor: @unchecked Sendable {
    let pid: pid_t
    private let source: DispatchSourceProcess

    init(pid: pid_t, onExit: @escaping @MainActor @Sendable () -> Void) {
        self.pid = pid
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { onExit() }
        }
        source.resume()
        // Registration fails silently if the process is already gone.
        if kill(pid, 0) == -1 && errno == ESRCH {
            DispatchQueue.main.async { MainActor.assumeIsolated { onExit() } }
        }
    }

    deinit {
        source.cancel()
    }

    /// True once the process no longer exists (exited and reaped — no zombie).
    var isGone: Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }
}
