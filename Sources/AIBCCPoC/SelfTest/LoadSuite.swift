import AppKit

/// ST-02: keystroke → PTY latency while terminals are flooded with exactly
/// 100k lines (80 ASCII + 10 Hangul each). Only samples sent while the flood
/// is running (between flood_start and flood_done) count. The threshold is the
/// pre-registered candidate; parent ST-02 stays unverified until the v1.6.1
/// baseline exists.
@MainActor
struct LoadSuite {
    let harness: SelfTestHarness

    private typealias Sample = (byte: UInt8, wall: Double)

    func run() async -> [TestResult] {
        [
            await measure(id: "ST-02a", label: "1분할 10만 줄", layout: .single, lines: 100_000),
            await measure(id: "ST-02b", label: "4분할 각 10만 줄", layout: .quad, lines: 100_000),
            // Deviation documented in docs/results: a single pane consumes 100k
            // lines in tens of ms, too short to sample; 1M lines widens the window.
            await measure(id: "ST-02c", label: "1분할 100만 줄(측정 창 확대)", layout: .single, lines: 1_000_000),
        ]
    }

    private func measure(id: String, label: String, layout: PaneLayout, lines: Int) async -> TestResult {
        let start = ContinuousClock.now
        let go = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-flood-go-\(UUID().uuidString)")
        let floods = (1...layout.paneCount).compactMap {
            harness.makeRecorderPane(name: "flood-\($0)",
                                     environment: ["AIBCC_GO_FILE": go.path, "FLOOD_LINES": "\(lines)"],
                                     script: AppConstants.Paths.floodScript)
        }
        guard floods.count == layout.paneCount, let window = harness.window, let target = floods.first else {
            return failure(id, "setup", start)
        }
        await harness.install(floods.map(\.pane), layout: layout)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { floods.allSatisfy { $0.log.isReady } }
        harness.focus(target.pane)
        await harness.drain()
        let mark = target.log.mark()
        FileManager.default.createFile(atPath: go.path, contents: nil)
        let started = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) {
            floods.allSatisfy { $0.log.firstEvent("flood_start") != nil }
        }
        guard started else { return failure(id, "flood did not start", start) }
        let sent = await typeTimed(count: AppConstants.SelfTest.latencySamples, window: window)
        _ = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            target.log.byteArrivals(since: mark).count >= sent.count
        }
        return verdict(id: id, label: label, sent: sent, log: target.log, mark: mark, start: start)
    }

    /// Types a…z repeatedly, one key per interval, recording wall-clock send time.
    private func typeTimed(count: Int, window: NSWindow) async -> [Sample] {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var sent: [Sample] = []
        for index in 0..<count {
            let letter = letters[index % letters.count]
            guard let key = EventSynthesizer.key(letter), let ascii = letter.asciiValue else { continue }
            sent = sent + [(byte: ascii, wall: Date().timeIntervalSince1970)]
            EventSynthesizer.press(key, in: window)
            await harness.pause(AppConstants.SelfTest.latencyKeyInterval)
        }
        return sent
    }

    private func verdict(
        id: String, label: String, sent: [Sample], log: RecorderLog, mark: Int,
        start: ContinuousClock.Instant
    ) -> TestResult {
        let arrivals = log.byteArrivals(since: mark)
        let floodStart = log.firstEvent("flood_start")?.wall ?? .infinity
        let floodDone = log.firstEvent("flood_done")?.wall ?? .infinity
        let floodError = log.firstEvent("flood_error") != nil
        let ordered = arrivals.map(\.byte) == sent.map(\.byte)
        let pairs = zip(sent, arrivals).filter { pair in pair.0.wall >= floodStart && pair.0.wall <= floodDone }
        let latencies = pairs.compactMap { pair in pair.1.wall.map { ($0 - pair.0.wall) * 1000 } }.sorted()
        let invalid = latencies.contains { $0 < 0 } || latencies.count < pairs.count
        let enough = latencies.count >= AppConstants.SelfTest.latencyMinimumValidSamples
        let base: [String: String] = [
            "sent": "\(sent.count)", "received": "\(arrivals.count)", "ordered": "\(ordered)",
            "samples_during_flood": "\(latencies.count)", "flood_error": "\(floodError)",
            "flood_lines": "\(log.firstEvent("flood_done")?.lines.map(String.init) ?? "running")",
        ]
        let floodMs = log.firstEvent("flood_done")?.wall.map { ($0 - floodStart) * 1000 }
        let evidence = base.merging(["flood_ms": floodMs.map { String(format: "%.0f", $0) } ?? "n/a"]) { $1 }
        guard ordered, !invalid, !floodError else {
            return .make(id, "출력 폭주 중 입력 지연 — 측정 무효(\(label))", status: .fail,
                         evidence: evidence, startedAt: start)
        }
        // Too few samples overlapped the flood: the window was too short to
        // judge, which is not evidence of a latency problem.
        guard enough, let p95 = percentile(latencies, 0.95) else {
            return .make(id, "출력 폭주 중 입력 지연 — 측정 창 부족(\(label))", status: .unverified,
                         evidence: evidence, startedAt: start)
        }
        let budget = AppConstants.SelfTest.latencyP95BudgetMs
        let stats = [
            "p50_ms": String(format: "%.1f", percentile(latencies, 0.5) ?? 0),
            "p95_ms": String(format: "%.1f", p95),
            "max_ms": String(format: "%.1f", latencies.last ?? 0),
        ]
        return .make(id, "출력 폭주 중 입력→PTY p95 ≤ \(Int(budget))ms (후보값, \(label))",
                     status: p95 <= budget ? .pass : .fail,
                     evidence: evidence.merging(stats) { $1 }, startedAt: start)
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    private func failure(_ id: String, _ reason: String, _ start: ContinuousClock.Instant) -> TestResult {
        .make(id, "부하 측정 준비", status: .fail, cause: .app, evidence: ["reason": reason], startedAt: start)
    }
}
