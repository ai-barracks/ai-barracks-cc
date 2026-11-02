import Foundation
import Observation
import UserNotifications

/// In-app toasts and macOS notifications (v1: NotificationToast +
/// tauri notification plugin).
struct AppNotice: Identifiable, Sendable {
    enum Kind: String, Sendable { case stale, sync, attention }

    let id = UUID()
    let kind: Kind
    let title: String
    let body: String
    let actionLabel: String?
    let barrackID: String?
    let sessionID: String?
}

@MainActor
@Observable
final class NoticeCenter {
    private(set) var notices: [AppNotice] = []
    @ObservationIgnored private let native: Bool

    /// Self-test runs never ask for notification permission.
    init(native: Bool = !CommandLine.arguments.contains { $0.hasPrefix("--selftest") }) {
        self.native = native
        if native {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func post(_ notice: AppNotice) {
        notices = Array((notices + [notice]).suffix(AppConstants.Health.maxToasts))
        if native {
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notice.id.uuidString,
                                                                         content: content, trigger: nil))
        }
        let id = notice.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: AppConstants.Health.toastLifetime)
            self?.dismiss(id)
        }
    }

    func dismiss(_ id: UUID) {
        notices.removeAll { $0.id == id }
    }
}
