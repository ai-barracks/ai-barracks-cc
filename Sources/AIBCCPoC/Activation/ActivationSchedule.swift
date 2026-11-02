import Foundation

/// Scheduled activation (CC v1.6.1 activation.rs): at 06/11/16/21 KST one
/// minimal "OK" request per selected CLI, on the subscription login only.
/// No catch-up, no retries, no project context, no API-key fallback.
///
/// The file is v1's own (`activation.json` next to `activation.lock` in
/// v1's support directory), in v1's exact schema: v1 and v2 share the
/// setting and the lock, so whichever app runs first schedules and a slot
/// is never activated twice.
/// Why an activation step failed, as recorded in the history and shown.
struct ActivationFailure: Error, Equatable, ExpressibleByStringInterpolation {
    let message: String

    init(_ message: String) { self.message = message }
    init(stringLiteral value: String) { message = value }
    init(stringInterpolation: DefaultStringInterpolation) { message = String(stringInterpolation: stringInterpolation) }
}

enum ActivationProvider: String, Codable, CaseIterable, Comparable, Sendable {
    case claude, codex

    var binaryName: String { rawValue }
    var label: String { self == .claude ? "Claude Code" : "Codex" }

    static func < (lhs: ActivationProvider, rhs: ActivationProvider) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct ActivationConfig: Codable, Equatable, Sendable {
    var enabled = false
    var claude = true
    var codex = true

    func selected(_ provider: ActivationProvider) -> Bool { provider == .claude ? claude : codex }
}

struct ActivationRun: Codable, Equatable, Sendable {
    let provider: ActivationProvider
    let slot: String
    var status: String
    var detail: String
}

/// v1 `Document` (serde field names).
struct ActivationDocument: Codable, Equatable, Sendable {
    var version = 1
    var config = ActivationConfig()
    var lastClaimed: [ActivationProvider: Int64] = [:]
    var history: [ActivationRun] = []

    enum CodingKeys: String, CodingKey {
        case version, config, history
        case lastClaimed = "last_claimed"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        config = try container.decodeIfPresent(ActivationConfig.self, forKey: .config) ?? ActivationConfig()
        history = try container.decodeIfPresent([ActivationRun].self, forKey: .history) ?? []
        let raw = try container.decodeIfPresent([String: Int64].self, forKey: .lastClaimed) ?? [:]
        lastClaimed = Dictionary(uniqueKeysWithValues: try raw.map { key, value in
            guard let provider = ActivationProvider(rawValue: key) else {
                throw DecodingError.dataCorruptedError(forKey: .lastClaimed, in: container, debugDescription: "provider")
            }
            return (provider, value)
        })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(config, forKey: .config)
        try container.encode(Dictionary(uniqueKeysWithValues: lastClaimed.map { ($0.key.rawValue, $0.value) }), forKey: .lastClaimed)
        try container.encode(history, forKey: .history)
    }
}

enum ActivationSchedule {
    static let hours = [6, 11, 16, 21]
    static let prompt = "Reply exactly OK. Do not use any tools."
    static let historyLimit = 80
    static let maxFileSize = 256 * 1024
    static let kst = TimeZone(secondsFromGMT: 9 * 3600)!

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = kst
        return calendar
    }

    /// The slot `now` falls in (minute :00 of a slot hour, KST), if any.
    static func slot(at now: Date) -> Date? {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        guard let hour = parts.hour, hours.contains(hour), parts.minute == 0 else { return nil }
        return calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: hour))
    }

    /// The first slot strictly after `now`.
    static func nextSlot(after now: Date) -> Date {
        let day = calendar.startOfDay(for: now)
        for offset in 0...1 {
            for hour in hours {
                if let slot = calendar.date(byAdding: DateComponents(day: offset, hour: hour), to: day), slot > now { return slot }
            }
        }
        return now
    }

    /// RFC 3339 in KST, as v1 writes `slot`.
    static func format(_ slot: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = kst
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: slot)
    }

    /// v1 load rules: size cap, regular file, version 1, a selection when
    /// enabled; runs left pending/running by a crash become interrupted
    /// (never retried); history capped.
    static func decode(_ data: Data) -> Result<ActivationDocument, ActivationFailure> {
        guard data.count <= maxFileSize, var document = try? JSONDecoder().decode(ActivationDocument.self, from: data) else {
            return .failure("예약 파일이 잘못되어 예약을 껐습니다")
        }
        guard document.version == 1 else { return .failure("지원하지 않는 예약 파일 버전") }
        guard !document.config.enabled || document.config.claude || document.config.codex else { return .failure("선택된 CLI 없음") }
        for index in document.history.indices where ["running", "pending"].contains(document.history[index].status) {
            document.history[index].status = "interrupted"
            document.history[index].detail = "App exited; not retried"
        }
        document.history = Array(document.history.prefix(historyLimit))
        return .success(document)
    }

    static func encode(_ document: ActivationDocument) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(document)
    }
}
