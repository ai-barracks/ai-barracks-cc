import Foundation
import GhosttyTerminal

/// Codex r6 (2026-11-05) findings on the r4/r5 fixes, each as a regression.
@MainActor
struct ReviewR6Suite {
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.withLock { items.append(item) } }
        var all: [String] { lock.withLock { items } }
    }

    func run() -> [TestResult] {
        [backlogReentry()]
    }

    /// R6-01a: libghostty patch 4 delivered backlog changes holding a lock,
    /// so a handler that replaced itself (or another thread waiting on that
    /// lock while holding the session's) deadlocked.
    private func backlogReentry() -> TestResult {
        let start = ContinuousClock.now
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let seen = Seen()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            session.setOutputBacklogHandler(highWater: 1000, lowWater: 100) { backlogged in
                seen.add("first:\(backlogged):\(session.pendingOutputByteCount)")
                guard backlogged else { return }
                session.setOutputBacklogHandler(highWater: 1000, lowWater: 100) { again in seen.add("second:\(again)") }
            }
            // No surface: the bytes stay queued and cross the high-water mark.
            session.receive(Data(repeating: 0x61, count: 2000))
            done.signal()
        }
        let finished = done.wait(timeout: .now() + 5) == .success
        let ok = finished && seen.all == ["first:true:2000", "second:true"]
        return .make("R6-01a", "backlog 통지 handler가 세션을 다시 불러도 교착 없음, 순서 유지",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["finished": "\(finished)", "seen": seen.all.joined(separator: ",")], startedAt: start)
    }
}
