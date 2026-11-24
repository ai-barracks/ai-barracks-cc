import AppKit

/// Delivery acknowledgement for posted synthetic events (Codex review r2 #6).
/// A sentinel `.applicationDefined` event is posted after the test events;
/// because the queue is FIFO, seeing the sentinel in a local monitor proves
/// every earlier event has been dispatched through `NSApp.sendEvent`.
@MainActor
final class EventBarrier {
    static let shared = EventBarrier()
    private static let sentinelSubtype: Int16 = 0x4143

    private var monitor: Any?
    private var issued = 0
    private var acknowledged = 0

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { [weak self] event in
            guard event.subtype.rawValue == EventBarrier.sentinelSubtype else { return event }
            let token = event.data1
            MainActor.assumeIsolated { self?.acknowledge(token) }
            return nil
        }
    }

    /// Posts a sentinel behind everything already queued and returns its token.
    func post(windowNumber: Int) -> Int {
        install()
        issued += 1
        guard let sentinel = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            subtype: EventBarrier.sentinelSubtype,
            data1: issued,
            data2: 0
        ) else { return issued }
        NSApp.postEvent(sentinel, atStart: false)
        return issued
    }

    func isAcknowledged(_ token: Int) -> Bool {
        acknowledged >= token
    }

    private func acknowledge(_ token: Int) {
        acknowledged = max(acknowledged, token)
    }
}
