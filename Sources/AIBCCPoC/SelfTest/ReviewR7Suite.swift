import Foundation
import GhosttyTerminal
import PtyProtocol

/// Codex r7 (2026-11-05) findings on the r6 fixes, each as a regression.
@MainActor
struct ReviewR7Suite {
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.withLock { items.append(item) } }
        var all: [String] { lock.withLock { items } }
    }

    func run() async -> [TestResult] {
        [await daemonUpgrade(), documents(), backlogOrder(), lockPath(), layoutMinimums()]
    }

    private func result(_ id: String, _ title: String, _ failures: [String], _ start: ContinuousClock.Instant) -> TestResult {
        .make(id, title, status: failures.isEmpty ? .pass : .fail, cause: .app,
              evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// R7-01a: an app update kept talking to the daemon the old build left
    /// running. A daemon that does not answer HELLO is replaced when idle,
    /// kept (and reported) while it holds live sessions; meanwhile its
    /// FAILURE for refused input does not end a pane.
    private func daemonUpgrade() async -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("aibcc-r7-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let fixtures = Bundle.main.resourceURL?.appendingPathComponent(AppConstants.Paths.fixturesDirectory),
              let daemon = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(AppConstants.Daemon.executableName)
        else { return result("R7-01a", "이전 데몬 교체", ["no bundle"], start) }
        let socket = directory.appendingPathComponent("d.sock").path
        let backend = DaemonBackend(socketPath: socket, executable: daemon)
        let legacy = { (alive: Int) -> Process? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: AppConstants.Paths.python)
            process.arguments = [fixtures.appendingPathComponent("legacy_ptyd.py").path, socket, "\(alive)"]
            guard (try? process.run()) != nil else { return nil }
            for _ in 0 ..< 50 where !FileManager.default.fileExists(atPath: socket) { usleep(50_000) }
            return process
        }
        // Busy: its sessions are the user's work, so it stays.
        let busy = legacy(1)
        let kept = await Task.detached { backend.upgradeIfOutdated() }.value
        if kept != .outdated(sessions: 1) { failures.append("busy \(kept)") }
        if busy?.isRunning != true { failures.append("busy daemon stopped") }
        busy?.terminate()
        busy?.waitUntilExit()
        try? FileManager.default.removeItem(atPath: socket)
        // Idle: replaced by this build's daemon.
        let idle = legacy(0)
        let replaced = await Task.detached { backend.upgradeIfOutdated() }.value
        let revision = await Task.detached { backend.revision() }.value
        if replaced != .replaced || revision != PtyProtocol.revision { failures.append("idle \(replaced) revision \(revision)") }
        idle?.waitUntilExit()
        backend.shutdownSessions()
        // The old daemon's refusal reads as a warning.
        if case .inputRefused = DaemonSession.event(forFailure: "input refused: the program is not reading its input") {} else {
            failures.append("legacy refusal ends the pane")
        }
        if case .failed = DaemonSession.event(forFailure: "unknown session") {} else { failures.append("real failure hidden") }
        return result("R7-01a", "업데이트 후 남은 이전 데몬: 세션 없으면 교체, 있으면 유지·알림, 이전 데몬의 입력 거부는 경고", failures, start)
    }

    /// R7-01b: shapes the r6 guards still let through.
    private func documents() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        for raw in ["name: a\nmodels:\n  primary: &m \"first\n  second\"\n",
                    "name: a\nmodels:\n  primary: !!str \"first\n  second\"\n",
                    "name: a\nmodels:\n  primary: &m sonnet\n  fallback:\n    - *m\n"] {
            var next = AgentYamlDocument.parse(raw)
            next.primaryModel = "new"
            if AgentYamlDocument.patch(raw, to: next) != .failure(.init(field: .primaryModel, reason: .nodeProperties)) {
                failures.append("yaml primary \(raw.dropFirst(18).prefix(14))")
            }
        }
        let alias = "name: a\nmodels:\n  primary: p\n  fallback:\n    - *m\n"
        var aliasNext = AgentYamlDocument.parse(alias)
        aliasNext.fallbackModels = ["x"]
        if AgentYamlDocument.patch(alias, to: aliasNext) != .failure(.init(field: .fallbackModels, reason: .nodeProperties)) {
            failures.append("yaml fallback alias")
        }
        for tail in ["#tag\n", "####### seven\n"] {
            let rules = "## Must Always\n- a\n- b\n" + tail + "\n## Must Never\n\n## Learned\n"
            var next = RulesDocument.parse(rules)
            next.mustAlways = ["a"]
            if case let .failure(failure) = RulesDocument.patch(rules, to: next), failure.reason == .nestedBullets {} else {
                failures.append("rules \(tail.prefix(6))")
            }
            let growth = "| 세션 중 이벤트 | 기록 위치 | 예시 |\n|---|---|---|\n| E | L | X |\n\n**NOT growth-worthy** — 기록하지 않을 것:\n- a\n- b\n" + tail
            var data = GrowthDocument.parse(growth)
            data.notGrowthWorthy = ["a"]
            if case .failure(.init(field: .notGrowthWorthy, reason: .nestedBullets)) = GrowthDocument.patch(growth, to: data) {} else {
                failures.append("growth \(tail.prefix(6))")
            }
        }
        let heading = "## Must Always\n- a\n- b\n## Must Never\n\n## Learned\n"
        var headingNext = RulesDocument.parse(heading)
        headingNext.mustAlways = ["a"]
        if case .failure = RulesDocument.patch(heading, to: headingNext) { failures.append("real heading refused") }
        return result("R7-01b", "YAML anchor·tag·alias 값, 목록 뒤 #tag·7개 #은 폼 저장 거부(진짜 heading은 허용)", failures, start)
    }

    /// R7-01c: backlog changes from two threads. While the first change's
    /// handler runs, a second thread's change is queued — it neither waits
    /// for the handler (patch 4's held lock) nor runs beside it (no queue,
    /// where a late `true` could land after `false`) — and follows in order.
    private func backlogOrder() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let seen = Seen()
        let inHandler = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        session.setOutputBacklogHandler(highWater: 1_500_000, lowWater: 1_200_000) { backlogged in
            seen.add("\(backlogged)")
            if backlogged {
                inHandler.signal()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        // No surface: 1.6 MB crosses high water; another 0.5 MB passes the
        // detached 2 MiB cap, the queue is trimmed to 1 MiB, below low water.
        Thread.detachNewThread { session.receive(Data(repeating: 0x61, count: 1_600_000)) }
        if inHandler.wait(timeout: .now() + 5) != .success { failures.append("no first change") }
        let second = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            session.receive(Data(repeating: 0x62, count: 500_000))
            second.signal()
        }
        if second.wait(timeout: .now() + 2) != .success { failures.append("second writer waited for the handler") }
        if seen.all != ["true"] { failures.append("delivered beside the handler \(seen.all)") }
        release.signal()
        for _ in 0 ..< 100 where seen.all.count < 2 { usleep(20_000) }
        if seen.all != ["true", "false"] { failures.append("order \(seen.all)") }
        return result("R7-01c", "두 스레드의 backlog 변화: 두 번째는 기다리지도 끼어들지도 않고 순서대로 전달", failures, start)
    }

    /// LY-01 (2026-11-06): every center destination, the Outputs panel and
    /// the sidebar fit what a minimum-size window leaves them. Measured in a
    /// probe child (SelfTestProbe) so a regression cannot wedge this run.
    private func layoutMinimums() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        if let app = Bundle.main.executableURL {
            let options = BoundedProcess.Options(timeout: AppConstants.SelfTest.probeTimeout, outputLimit: 64 * 1024, tag: "probe")
            switch BoundedProcess.run(app, [SelfTestProbe.argumentPrefix + SelfTestProbe.layoutMinimums],
                                      cwd: FileManager.default.temporaryDirectory,
                                      environment: ProcessInfo.processInfo.environment, options: options, cancelled: { false }) {
            case let .success(output) where output.status == 0: break
            case let .success(output): failures.append(String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            case let .failure(failure): failures.append("probe \(failure)")
            }
        } else {
            failures.append("no executable")
        }
        return result("LY-01a", "화면별 최소 폭·높이가 최소 창에서 각 열에 남는 공간 안", failures, start)
    }

    /// R7-01d: the development and release apps lock the same file for
    /// the same registry (each locked its own support folder).
    private func lockPath() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let shared = AibWriteLock.path(selfTest: false, registry: "~/.aib/barracks.json")
        let expanded = AibWriteLock.path(selfTest: false, registry: ("~/.aib/barracks.json" as NSString).expandingTildeInPath)
        let other = AibWriteLock.path(selfTest: false, registry: "/tmp/other/barracks.json")
        if shared != expanded { failures.append("same registry, two locks") }
        if shared == other { failures.append("different registries share a lock") }
        if !shared.hasPrefix((AppConstants.Maintenance.sharedSupportDirectory as NSString).expandingTildeInPath) {
            failures.append("not in the shared folder \(shared)")
        }
        if AibWriteLock.path(selfTest: true, registry: "~/.aib/barracks.json") == shared { failures.append("self-test uses the real lock") }
        return result("R7-01d", "aib 쓰기 잠금은 레지스트리 기준·개발/출시 앱 공통(self-test는 분리)", failures, start)
    }
}
