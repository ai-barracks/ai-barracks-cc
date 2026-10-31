import AppKit
import Foundation

/// Exit codes of `AIBCCPoC --selftest`.
enum SelfTestExit: Int32 {
    /// Every blocking criterion passed (only possible with human evidence merged in).
    case allBlockingPassed = 0
    case blockingFailure = 1
    case setupError = 2
    /// No blocking failure, but some blocking criteria are still unverified.
    case incomplete = 3
    case reportWriteFailed = 4
}

/// Entry point for `--selftest`: runs every automatable suite in the real app
/// window, writes `report.json`, restores the input source and exits.
@MainActor
enum SelfTestLauncher {
    static func runIfRequested(workspace: WorkspaceModel, artifacts: ArtifactStore) async {
        guard CommandLine.arguments.contains(AppConstants.SelfTest.argument) else { return }
        let runner = SelfTestRunner(workspace: workspace, artifacts: artifacts)
        let outcome = await runner.run()
        InputSourceGuard.restore()
        exit(outcome.rawValue)
    }
}

@MainActor
struct SelfTestRunner {
    let workspace: WorkspaceModel
    let artifacts: ArtifactStore

    func run() async -> SelfTestExit {
        guard let output = makeOutputDirectory() else { return .setupError }
        let harness = SelfTestHarness(workspace: workspace, artifacts: artifacts, outputDirectory: output)
        NSApp.activate()
        guard await harness.waitUntil(AppConstants.SelfTest.readyTimeout, { harness.window != nil }) else {
            return .setupError
        }
        harness.window?.makeKeyAndOrderFront(nil)
        let environment = environmentSnapshot()
        let startedAt = Date()

        let measured = await InputSuite(harness: harness).run()
            + (await ResizeSuite(harness: harness).run())
            + (await SelectionSuite(harness: harness).run())
            + (await LifecycleSuite(harness: harness).run())
            + (await IntegrationSuite(harness: harness).run())
        let subs = measured + CriteriaCatalog.pendingSubResults(excluding: Set(measured.map(\.id)))
        let parents = CriteriaCatalog.aggregate(subs)
        let report = SelfTestReport(startedAt: startedAt, finishedAt: Date(), environment: environment,
                                    results: parents + subs)
        do {
            try write(report, to: output)
        } catch {
            FileHandle.standardError.write(Data("selftest: report write failed: \(error)\n".utf8))
            return .reportWriteFailed
        }
        return verdict(parents)
    }

    private func verdict(_ parents: [TestResult]) -> SelfTestExit {
        let blockingIDs = Set(CriteriaCatalog.criteria.filter(\.blocking).map(\.id))
        let blocking = parents.filter { blockingIDs.contains($0.id) }
        if blocking.contains(where: { $0.status == .fail }) { return .blockingFailure }
        if blocking.contains(where: { $0.status == .unverified }) { return .incomplete }
        return .allBlockingPassed
    }

    private func makeOutputDirectory() -> URL? {
        let base = ProcessInfo.processInfo.environment[AppConstants.SelfTest.outputDirectoryEnv]
            ?? (AppConstants.SelfTest.defaultOutputDirectory as NSString).expandingTildeInPath
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let directory = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(stamp, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }

    private func environmentSnapshot() -> [String: String] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "app_version": info["CFBundleShortVersionString"] as? String ?? "unknown",
            "lang": ProcessInfo.processInfo.environment[AppConstants.Environment.lang] ?? "unset",
            "input_source_at_start": InputSourceGuard.currentSourceID ?? "unknown",
            "backing_scale": "\(NSScreen.main?.backingScaleFactor ?? 0)",
            "barracks": "\(workspace.barracks.count)",
        ]
    }

    private func write(_ report: SelfTestReport, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        let summary = report.counts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        try "\(summary)\n\(directory.path)\n".write(
            to: directory.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8
        )
    }
}
