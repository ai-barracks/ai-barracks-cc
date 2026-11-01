import Foundation
import GhosttyTerminal

/// PK-01 (known issue #1): the app runs on its own resources. PK-01a checks
/// where Ghostty's resources resolve; PK-01b is meaningful only when
/// scripts/verify-standalone.sh has moved the build-path bundle aside, so a
/// lookup through SwiftPM's `Bundle.module` would have crashed the app.
@MainActor
struct PackagingSuite {
    let harness: SelfTestHarness

    func run() async -> [TestResult] {
        [resourcesInsideApp(), await standaloneRun()]
    }

    private func resourcesInsideApp() -> TestResult {
        let start = ContinuousClock.now
        let resources = Bundle.main.resourceURL?.standardizedFileURL.path ?? "/nonexistent"
        let bundlePath = GhosttyRuntimeResources.bundleURL.standardizedFileURL.path
        let ghosttyDir = GhosttyRuntimeResources.directoryURL?.path ?? ""
        let terminfo = GhosttyRuntimeResources.terminfoDirectoryURL?.path ?? ""
        let exported = getenv("GHOSTTY_RESOURCES_DIR").map { String(cString: $0) } ?? ""
        let menuTitle = harness.workspace.panes.first?.probeView?.selectionContextMenu().items.first?.title ?? ""
        let inside = [bundlePath, ghosttyDir, terminfo, exported].allSatisfy { $0.hasPrefix(resources + "/") }
        let present = FileManager.default.fileExists(atPath: ghosttyDir) && FileManager.default.fileExists(atPath: terminfo)
        return .make("PK-01a", "Ghostty 리소스·terminfo·현지화 문자열을 앱 번들 Contents/Resources에서 해석",
                     status: inside && present && !menuTitle.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["bundle": bundlePath, "resources_dir_env": exported,
                                "terminfo": terminfo, "copy_menu_title": menuTitle],
                     startedAt: start)
    }

    private func standaloneRun() async -> TestResult {
        let start = ContinuousClock.now
        let prefix = AppConstants.SelfTest.standaloneArgumentPrefix
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return .make("PK-01b", "빌드 경로 리소스 없이 실행", status: .unverified,
                         evidence: ["method": "scripts/verify-standalone.sh"], startedAt: start)
        }
        let buildBundle = String(argument.dropFirst(prefix.count))
        let absent = !FileManager.default.fileExists(atPath: buildBundle)
        // A terminal must actually start and take input without the build tree.
        guard absent, let recorder = harness.makeRecorderPane(name: "standalone"), let window = harness.window else {
            return .make("PK-01b", "빌드 경로 리소스 없이 실행", status: .fail, cause: .app,
                         evidence: ["build_bundle_absent": "\(absent)"], startedAt: start)
        }
        await harness.install([recorder.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorder.log.isReady }
        harness.focus(recorder.pane)
        let mark = recorder.log.mark()
        EventSynthesizer.type("ok", in: window)
        let typed = await harness.settledBytes(recorder.log, since: mark, expectingAtLeast: 2)
        return .make("PK-01b", "빌드 경로 리소스 없이 실행: 터미널 시작·입력 정상(크래시 없음)",
                     status: typed == Hex.bytes("ok") ? .pass : .fail, cause: .app,
                     evidence: ["build_bundle": buildBundle, "build_bundle_absent": "\(absent)",
                                "typed": Hex.string(typed)],
                     startedAt: start)
    }
}
