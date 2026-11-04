import Foundation

/// The app's aib commands that rewrite ~/.aib/barracks.json (sync, init,
/// barracks remove/refresh) run one at a time: aib's register_barrack has
/// no lock and two at once can drop or duplicate entries (r5).
@MainActor
enum AibWriteQueue {
    private static var tail: Task<Void, Never>?

    static func run<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task { () -> T in
            _ = await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }
}
