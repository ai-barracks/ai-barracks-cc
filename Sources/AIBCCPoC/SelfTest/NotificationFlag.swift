import Foundation

/// Becomes `fired` once a notification arrives (e.g. fullscreen animation
/// finished). Call `invalidate()` when done; no deinit-time cleanup so the
/// type stays free of nonisolated-deinit access to isolated state.
@MainActor
final class NotificationFlag {
    private(set) var fired = false
    private var token: (any NSObjectProtocol)?

    init(_ name: Notification.Name, object: AnyObject?) {
        token = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fired = true }
        }
    }

    func invalidate() {
        guard let token else { return }
        NotificationCenter.default.removeObserver(token)
        self.token = nil
    }
}
