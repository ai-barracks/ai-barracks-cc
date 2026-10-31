import AppKit
import Foundation

/// Entry point for `AIBCCPoC --selftest`. Runs every automatable suite in the
/// real app window, writes `report.json`, restores the input source and exits
/// with 1 when any blocking criterion failed.
@MainActor
enum SelfTestLauncher {
    static func runIfRequested(workspace: WorkspaceModel, artifacts: ArtifactStore) async {
        guard CommandLine.arguments.contains(AppConstants.SelfTest.argument) else { return }
        let runner = SelfTestRunner(workspace: workspace, artifacts: artifacts)
        let code = await runner.run()
        InputSourceGuard.restore()
        exit(code)
    }
}

@MainActor
struct SelfTestRunner {
    let workspace: WorkspaceModel
    let artifacts: ArtifactStore

    func run() async -> Int32 {
        guard let output = makeOutputDirectory() else { return 2 }
        let harness = SelfTestHarness(workspace: workspace, artifacts: artifacts, outputDirectory: output)
        NSApp.activate()
        let hasWindow = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { harness.window != nil }
        guard hasWindow else { return 2 }
        harness.window?.makeKeyAndOrderFront(nil)

        let startedAt = Date()
        let environment = environmentSnapshot()
        let measured = await InputSuite(harness: harness).run()
            + (await ResizeSuite(harness: harness).run())
            + (await SelectionSuite(harness: harness).run())
            + (await IntegrationSuite(harness: harness).run())
        let all = measured + RegressionMapper.derive(from: measured) + ManualChecklist.pending()
        let report = SelfTestReport(startedAt: startedAt, finishedAt: Date(), environment: environment, results: all)
        write(report, to: output)
        let blockingFailure = all.contains {
            $0.status == .fail && !AppConstants.SelfTest.nonBlockingIDs.contains($0.id)
        }
        return blockingFailure ? 1 : 0
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

    private func write(_ report: SelfTestReport, to directory: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: directory.appendingPathComponent("report.json"))
        let summary = report.counts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        try? "\(summary)\n\(directory.path)\n".write(
            to: directory.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8
        )
    }
}

/// RG-01..04: the four aibcc v1.6.1 regressions, derived from measured tests
/// so the same evidence backs both IDs.
enum RegressionMapper {
    static func derive(from results: [TestResult]) -> [TestResult] {
        let byID = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let start = ContinuousClock.now
        func combine(_ id: String, _ title: String, _ sources: [String]) -> TestResult {
            let found = sources.compactMap { byID[$0] }
            let status: TestStatus = found.count < sources.count ? .unverified
                : found.contains { $0.status == .fail } ? .fail
                : found.allSatisfy { $0.status == .pass } ? .pass : .unverified
            return .make(id, title, status: status, cause: .unknown,
                         evidence: ["from": sources.joined(separator: ",")], startedAt: start)
        }
        return [
            combine("RG-01", "한글 조합 누락·분리 (계약 층)", ["IN-01", "IN-02"]),
            combine("RG-02", "붙여넣기 중복 입력", ["IN-07"]),
            combine("RG-03", "스페이스 20+c2a0 이중 송신", ["IN-05", "IN-01"]),
            combine("RG-04", "리사이즈 마지막 행·열 잘림", ["RS-01", "RS-04"]),
        ]
    }
}

/// Criteria that need a person (physical keyboard IME, readability) or Codex
/// computer-use (split drag, reference captures). Always `unverified` here —
/// the self-test never declares them passed.
enum ManualChecklist {
    static func pending() -> [TestResult] {
        let start = ContinuousClock.now
        let items: [(String, String, IMELayer?, String)] = [
            ("IN-01-phys", "실제 키보드 한글 연속 입력", .physicalKeyboardIME, "human"),
            ("IN-02-phys", "실제 키보드 조합 중 Backspace", .physicalKeyboardIME, "human"),
            ("IN-03", "한/영 전환 직후 첫 글자", .physicalKeyboardIME, "human"),
            ("IN-04-phys", "조합 중 pane 클릭 전환", .physicalKeyboardIME, "human"),
            ("IN-08", "bracketed paste 종료 구분자 정책", nil, "human"),
            ("IN-12", "후보창 위치", .physicalKeyboardIME, "human"),
            ("RS-03-drag", "split 경계 드래그", nil, "codex-computer-use"),
            ("RS-05", "스크롤백 보존·프롬프트 reflow", nil, "human"),
            ("RS-06", "Claude Code TUI 잔해 레퍼런스 대비", nil, "codex-computer-use"),
            ("RS-07", "다른 해상도 모니터 이동", nil, "human"),
            ("SC-07", "스크롤하며 선택 확장", nil, "human"),
            ("RD-01", "한글 2칸 정렬·폴백 기준선", nil, "human"),
            ("RD-02", "다크/라이트 대비", nil, "human"),
            ("MD-02", "GFM 렌더링·실패 시 원문", nil, "human"),
            ("MD-05", "스크립트·외부 리소스 차단", nil, "code-review"),
            ("ST-02", "대량 출력 중 입력 지연 p95", nil, "baseline-first"),
            ("ST-04", "셸·앱 종료 시 프로세스 정리", nil, "human"),
        ]
        return items.map { id, title, layer, method in
            .make(id, title, status: .unverified, layer: layer, evidence: ["method": method], startedAt: start)
        }
    }
}
