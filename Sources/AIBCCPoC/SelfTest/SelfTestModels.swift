import Foundation

enum TestStatus: String, Codable, Sendable {
    case pass, fail, unverified
}

/// Five-way cause classification; an `unknown` P0 failure is a failure.
enum FailureCause: String, Codable, Sendable {
    case app, wrapper, engine, tui, unknown
}

/// IME evidence layers are reported separately and never summed.
enum IMELayer: String, Codable, Sendable {
    case imeCallbackContract, syntheticEventPath, physicalKeyboardIME
}

struct TestResult: Codable, Sendable {
    let id: String
    let title: String
    let status: TestStatus
    let layer: IMELayer?
    let cause: FailureCause?
    let evidence: [String: String]
    let durationMs: Double

    static func make(
        _ id: String,
        _ title: String,
        status: TestStatus,
        layer: IMELayer? = nil,
        cause: FailureCause? = nil,
        evidence: [String: String] = [:],
        startedAt: ContinuousClock.Instant
    ) -> TestResult {
        let millis = (ContinuousClock.now - startedAt).milliseconds
        return TestResult(
            id: id,
            title: title,
            status: status,
            layer: layer,
            cause: status == .fail ? (cause ?? .unknown) : nil,
            evidence: evidence,
            durationMs: millis
        )
    }
}

struct SelfTestReport: Codable, Sendable {
    let startedAt: Date
    let finishedAt: Date
    let environment: [String: String]
    let results: [TestResult]

    var counts: [String: Int] {
        Dictionary(grouping: results, by: { $0.status.rawValue }).mapValues(\.count)
    }
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

/// Hex helpers shared by suites and evidence output.
enum Hex {
    static func string(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    static func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }
}
