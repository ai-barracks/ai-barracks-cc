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
        let arguments = CommandLine.arguments
        let requested = arguments.contains(AppConstants.SelfTest.argument)
            || arguments.contains { $0.hasPrefix(AppConstants.SelfTest.onlyArgumentPrefix) }
        guard requested else { return }
        let runner = SelfTestRunner(workspace: workspace, artifacts: artifacts)
        let outcome = await runner.run()
        InputSourceGuard.restore()
        // The self-test daemon's fixture sessions end with the run, except
        // when the next launch must reattach (persist phase 1).
        if let daemon = workspace.daemon, !CommandLine.arguments.contains(where: { $0.contains("persist1") }) {
            daemon.shutdownSessions()
        }
        exit(outcome.rawValue)
    }
}

@MainActor
struct SelfTestRunner {
    let workspace: WorkspaceModel
    let artifacts: ArtifactStore

    func run() async -> SelfTestExit {
        guard let output = makeOutputDirectory() else { return .setupError }
        CrashTrace.install(in: output)
        // The self-test's own output archive starts empty each run (never the user's).
        let archive = workspace.scrollback.directory
        if archive.lastPathComponent == AppConstants.Scrollback.selfTestDirectory { try? FileManager.default.removeItem(at: archive) }
        let harness = SelfTestHarness(workspace: workspace, artifacts: artifacts, outputDirectory: output)
        NSApp.activate()
        guard await harness.waitUntil(AppConstants.SelfTest.readyTimeout, { harness.window != nil }) else {
            return .setupError
        }
        harness.window?.makeKeyAndOrderFront(nil)
        let restoredFrame = harness.window.map { NSStringFromRect($0.frame) } ?? "none"
        normalizeWindow(harness.window)
        // An inactive app treats the first click as an activation click, so
        // click-to-focus tests are only meaningful while active.
        NSRunningApplication.current.activate()
        let active = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { NSApp.isActive }
        let environment = environmentSnapshot().merging(["restored_window_frame": restoredFrame]) { $1 }
        // Clicks and menu shortcuts are meaningless for an inactive app (the
        // display may be asleep or another app holds focus): refuse to report
        // results that would be false failures.
        // Suites that send no input (window sizes, captures) are meaningful
        // in the background too, e.g. while a system alert holds the front.
        let needsActivation = !Self.requestedSuites().isSubset(of: Self.backgroundSuites)
        guard active || !needsActivation else {
            FileHandle.standardError.write(Data("selftest: app could not become active; rerun while the display is awake\n".utf8))
            try? "setup=app-inactive\n".write(to: output.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
            return .setupError
        }
        let startedAt = Date()

        GhosttyDebugCapture.enable(writingTo: output.appendingPathComponent("ghostty-debug.log"))
        let only = Self.requestedSuites()
        var measured: [TestResult] = []
        for name in Self.suiteOrder + Self.explicitSuites where only.contains(name) {
            measured = measured + (await runSuite(name, harness: harness))
        }
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
        return verdict(parents, measured: measured)
    }

    static let suiteOrder = ["unit", "packaging", "input", "resize", "selection", "lifecycle", "agents", "load", "integration"]
    /// Run only when named (they need a daemon and two app launches).
    static let explicitSuites = ["persist1", "persist2", "repro10", "repro-r5", "rs06", "gallery", "showcase", "ux"]
    static let allSuites = Set(suiteOrder)
    /// Need no keyboard or mouse: they run without the app in front.
    static let backgroundSuites: Set = ["ux"]
    static let knownSuites = Set(suiteOrder + explicitSuites)

    private func runSuite(_ name: String, harness: SelfTestHarness) async -> [TestResult] {
        switch name {
        case "unit": return UnitSuite().run() + DocumentSuite().run() + SkillSuite().run() + [OverviewSuite().run(), ScrollbackSuite().run(), V1ImportSuite().run()] + ActivationSuite().run() + [await ActivationSettingsTests.run(), CrashTraceProbe.run()] + (await UnitSuite().runAsync()) + (await GitSuite().run()) + (await ProviderSuite().run()) + [await ReviewR5Suite().run()] + ReviewR6Suite().run() + [await ReviewR6Suite().writeLock()] + (await ReviewR7Suite().run())
        case "agents": return await AgentSuite(harness: harness).run() + [await SkillSuite().syncIntegration(), await BarrackAdminSuite().run()]
        case "packaging": return await PackagingSuite(harness: harness).run()
        case "input": return await InputSuite(harness: harness).run()
        case "resize": return await ResizeSuite(harness: harness).run()
        case "selection": return await SelectionSuite(harness: harness).run()
        case "lifecycle": return await LifecycleSuite(harness: harness).run()
        case "load": return await LoadSuite(harness: harness).run()
        case "integration": return await IntegrationSuite(harness: harness).run()
        case "persist1": return await PersistSuite(harness: harness).phaseOne()
        case "repro10": return await ReproSuite(harness: harness).run()
        case "repro-r5": return await RenderSuite(harness: harness).run()
        case "rs06": return await TuiSuite(harness: harness).run()
        case "gallery": return await GallerySuite(harness: harness).run()
        case "ux": return await UxSuite(harness: harness).run()
        case "showcase": return await ShowcaseSuite(harness: harness).run()
        case "persist2":
            let suite = PersistSuite(harness: harness)
            return await suite.phaseTwo() + [await suite.replayFence(), await suite.archiveAfterOutput(),
                                             await suite.inputRefusalKeepsPane(), await suite.archiveEndedWhileDetached(),
                                             await suite.archiveReplacesSnapshot()] + suite.recovery()
        default: return []
        }
    }

    /// `--selftest-only=input,lifecycle` runs a subset (diagnosis only; a
    /// partial run can never produce exit 0 because criteria stay unverified).
    static func requestedSuites() -> Set<String> {
        let prefix = AppConstants.SelfTest.onlyArgumentPrefix
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }) else { return allSuites }
        let names = argument.dropFirst(prefix.count).split(separator: ",").map(String.init)
        return Set(names).intersection(knownSuites)
    }

    private func verdict(_ parents: [TestResult], measured: [TestResult]) -> SelfTestExit {
        // A suite that could not even set up invalidates the run (r2 #5).
        if measured.contains(where: { $0.id.hasSuffix("-setup") && $0.status == .fail }) { return .setupError }
        let blockingIDs = Set(CriteriaCatalog.criteria.filter(\.blocking).map(\.id))
        let blocking = parents.filter { blockingIDs.contains($0.id) }
        if blocking.contains(where: { $0.status == .fail }) { return .blockingFailure }
        if blocking.contains(where: { $0.status == .unverified }) { return .incomplete }
        return .allBlockingPassed
    }

    /// macOS restores the last window frame, which an earlier run may have
    /// left at the minimum size: every run starts from the default size so
    /// results do not depend on the previous one (known issue #11).
    private func normalizeWindow(_ window: NSWindow?) {
        guard let window else { return }
        window.setContentSize(NSSize(width: AppConstants.Layout.defaultWindowWidth,
                                     height: AppConstants.Layout.defaultWindowHeight))
        window.center()
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
            "app_active_at_start": "\(NSApp.isActive)",
            "pty_backend": workspace.daemon == nil ? "exec" : "daemon",
            "ptyd_socket": workspace.daemon?.socketPath ?? "none",
            "ptyd_restore": workspace.restoreSummary,
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
