import Foundation

/// One line written by Fixtures/pty_recorder.py.
struct RecorderEvent: Decodable, Sendable {
    let t: Double
    let kind: String
    let hex: String?
    let rows: Int?
    let cols: Int?
}

/// Reader for the recorder's JSONL log — the ground truth of what the PTY
/// actually received.
struct RecorderLog: Sendable {
    let url: URL

    static func makeTemporary(name: String) -> RecorderLog {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibcc-poc-\(name)-\(UUID().uuidString).jsonl")
        return RecorderLog(url: file)
    }

    func events() -> [RecorderEvent] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(RecorderEvent.self, from: Data(line.utf8))
        }
    }

    var isReady: Bool {
        events().contains { $0.kind == "ready" }
    }

    /// Opaque position marker: number of events seen so far.
    func mark() -> Int {
        events().count
    }

    func bytes(since mark: Int) -> [UInt8] {
        events().dropFirst(mark)
            .filter { $0.kind == "bytes" }
            .flatMap { Self.decode(hex: $0.hex ?? "") }
    }

    func lastWinsize() -> (rows: Int, cols: Int)? {
        guard let last = events().last(where: { $0.kind == "winsize" || $0.kind == "ready" }),
              let rows = last.rows, let cols = last.cols
        else { return nil }
        return (rows, cols)
    }

    private static func decode(hex: String) -> [UInt8] {
        hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    }
}
