import AppKit

/// ST-02a: keystroke → PTY latency while the terminal is flooded with output
/// (80 ASCII + 10 Hangul per line). Threshold is the pre-registered candidate;
/// the parent ST-02 stays unverified until the v1.6.1 baseline exists.
@MainActor
struct LoadSuite {
    let harness: SelfTestHarness

    func run() async -> [TestResult] {
        [await latencyUnderFlood()]
    }

    private func latencyUnderFlood() async -> TestResult {
        let start = ContinuousClock.now
        guard let window = harness.window,
              let flood = harness.makeRecorderPane(name: "flood", script: AppConstants.Paths.floodScript)
        else { return failure("setup", start) }
        await harness.install([flood.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { flood.log.isReady }
        await harness.pause(.milliseconds(300))
        harness.focus(flood.pane)
        let mark = flood.log.mark()
        let sent = await typeTimed(count: AppConstants.SelfTest.latencySamples, window: window)
        _ = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            flood.log.byteArrivals(since: mark).count >= sent.count
        }
        let arrivals = flood.log.byteArrivals(since: mark)
        return verdict(sent: sent, arrivals: arrivals, start: start)
    }

    /// Types a…z repeatedly, one key per interval, recording wall-clock send time.
    private func typeTimed(count: Int, window: NSWindow) async -> [(byte: UInt8, wall: Double)] {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var sent: [(byte: UInt8, wall: Double)] = []
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
        sent: [(byte: UInt8, wall: Double)],
        arrivals: [(byte: UInt8, wall: Double)],
        start: ContinuousClock.Instant
    ) -> TestResult {
        let ordered = arrivals.map(\.byte) == sent.map(\.byte)
        let latencies = zip(sent, arrivals).map { ($1.wall - $0.wall) * 1000 }.sorted()
        guard ordered, !latencies.isEmpty else {
            return .make("ST-02a", "대량 출력 중 입력 → PTY 지연 p95", status: .fail,
                         evidence: ["sent": "\(sent.count)", "received": "\(arrivals.count)", "ordered": "\(ordered)"],
                         startedAt: start)
        }
        let p50 = latencies[latencies.count / 2]
        let p95 = latencies[min(latencies.count - 1, Int(Double(latencies.count) * 0.95))]
        let budget = AppConstants.SelfTest.latencyP95BudgetMs
        return .make("ST-02a", "대량 출력 중 입력 → PTY 지연 p95 ≤ \(Int(budget))ms (후보값)",
                     status: p95 <= budget ? .pass : .fail,
                     evidence: ["p50_ms": String(format: "%.1f", p50), "p95_ms": String(format: "%.1f", p95),
                                "max_ms": String(format: "%.1f", latencies.last ?? 0), "samples": "\(latencies.count)"],
                     startedAt: start)
    }

    private func failure(_ reason: String, _ start: ContinuousClock.Instant) -> TestResult {
        .make("ST-setup", "부하 스위트 준비", status: .fail, cause: .app,
              evidence: ["reason": reason], startedAt: start)
    }
}
