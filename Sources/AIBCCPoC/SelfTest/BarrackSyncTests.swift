import Foundation

/// SY-01a (Codex parity audit P05): v1 System's batch sync against a fake
/// runner — versions read from agent.yaml, "업데이트 필요만" picks the stale
/// ones, a run goes one barrack at a time in list order with the selection
/// fixed at its start, a failure is recorded for that barrack only, and
/// the dry-run choice reaches the runner.
@MainActor
enum BarrackSyncTests {
    private actor Calls {
        var all: [(String, Bool)] = []
        func add(_ path: String, _ dry: Bool) { all.append((path, dry)) }
    }

    static func run() async -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let barracks = [("new", "aib_version: \"1.6.0\"\n"), ("old", "aib_version: 1.5.1\n"), ("bare", "name: x\n")].map { name, yaml in
            let folder = root.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? yaml.write(to: folder.appendingPathComponent("agent.yaml"), atomically: true, encoding: .utf8)
            return Barrack(name: name, path: folder.path, description: nil)
        }
        let calls = Calls()
        let model = BarrackSyncModel(barracks: barracks, cliVersion: "1.6.0") { path, dry in
            await calls.add(path, dry)
            try? await Task.sleep(for: .milliseconds(30))
            return BarrackSyncModel.Result(success: !path.hasSuffix("/old"), output: "out \(URL(fileURLWithPath: path).lastPathComponent)")
        }
        if model.rows.map(\.version) != ["1.6.0", "1.5.1", ""] { failures.append("versions \(model.rows.map(\.version))") }
        model.selectOutdated()
        if model.selected != [barracks[1].id] { failures.append("outdated pick") }
        await model.run()
        if await calls.all.map(\.1) != [true] { failures.append("dry run default") }
        model.selectAll()
        model.dryRun = false
        let running = Task { await model.run() }
        try? await Task.sleep(for: .milliseconds(10))
        model.selectNone()
        await running.value
        let real = await calls.all.dropFirst().map { URL(fileURLWithPath: $0.0).lastPathComponent + ($0.1 ? "-dry" : "") }
        if real != ["new", "old", "bare"] { failures.append("order/snapshot \(real)") }
        if model.results.count != 3 || model.results[barracks[1].id]?.success != false
            || model.results[barracks[0].id]?.output != "out new" || model.lastRunWasDry { failures.append("results") }
        await model.run()
        if await calls.all.count != 4 { failures.append("ran with nothing selected") }
        return .make("SY-01a", "배럭 골라서 Sync(v1 System): 버전 표·업데이트 필요만·선택 고정·배럭별 결과(실패 격리)·미리보기 기본",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }
}
