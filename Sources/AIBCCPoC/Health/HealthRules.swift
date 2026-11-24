import Foundation

/// CC v1.6.1 watcher.rs rules, as pure functions (testable without time
/// passing or notifications showing).
enum HealthRules {
    static let staleAfter: TimeInterval = 2 * 3600
    static let suppressFor: TimeInterval = 3600

    struct ActiveSession: Equatable, Sendable {
        let id: String
        let client: String
        let task: String
    }

    /// Active rows of SESSIONS.md: `| id | client | … | … | task |`.
    static func activeSessions(fromSessionsIndex text: String) -> [ActiveSession] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|"), !trimmed.contains("---"), !trimmed.contains("Session") else { return nil }
            let columns = trimmed.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 5, !columns[1].isEmpty else { return nil }
            let task = columns.count > 5 ? columns[5] : ""
            return ActiveSession(id: columns[1], client: columns[2],
                                 task: task.isEmpty || task == "(starting)" ? "(no task recorded)" : task)
        }
    }

    /// Stale = the session file has not changed for two hours.
    static func isStale(modified: Date, now: Date) -> Bool {
        now.timeIntervalSince(modified) > staleAfter
    }

    /// v1 re-notifies after an hour; keys no longer stale are forgotten.
    static func shouldNotify(key: String, notified: [String: Date], now: Date) -> Bool {
        guard let last = notified[key] else { return true }
        return now.timeIntervalSince(last) >= suppressFor
    }

    /// v1 announced "sync required" every 30 s while anything was
    /// outdated; v2 speaks when the situation changes or an hour passed.
    static func shouldAnnounceSync(outdated: [String], cliVersion: String,
                                   last: (signature: String, at: Date)?, now: Date) -> Bool {
        guard !outdated.isEmpty else { return false }
        let signature = cliVersion + ":" + outdated.sorted().joined(separator: ",")
        guard let last else { return true }
        return last.signature != signature || now.timeIntervalSince(last.at) >= suppressFor
    }

    static func syncSignature(outdated: [String], cliVersion: String) -> String {
        cliVersion + ":" + outdated.sorted().joined(separator: ",")
    }

    /// Sessions that started needing the user since the previous look.
    /// The first look (no previous) announces nothing.
    static func newlyNeedingAttention(previous: [String: [LiveSession]]?, current: [String: [LiveSession]]) -> [LiveSession] {
        guard let previous else { return [] }
        let before = Set(previous.values.flatMap { $0 }.filter(\.needsAttention).map { "\($0.id)#\($0.state.rawValue)" })
        return current.values.flatMap { $0 }.filter { $0.needsAttention && !before.contains("\($0.id)#\($0.state.rawValue)") }
    }
}
