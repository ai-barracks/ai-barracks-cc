import AppKit

/// Screens for visual review (explicit suite `--selftest-only=gallery`):
/// every destination and inspector tab of the selected barrack, set
/// programmatically and captured (needs scripts/capture-watcher.sh).
@MainActor
struct GallerySuite {
    let harness: SelfTestHarness

    func run() async -> [TestResult] {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        var captures: [String] = []
        workspace.isArtifactPanelVisible = true
        for destination in Destination.allCases {
            workspace.destination = destination
            await harness.pause(.seconds(2))
            if let image = await harness.requestCapture(label: "gallery-\(destination.rawValue)") {
                captures.append(image.lastPathComponent)
            }
        }
        workspace.destination = .sessions
        for tab in InspectorTab.allCases {
            workspace.inspectorTab = tab
            await harness.pause(.seconds(2))
            if let image = await harness.requestCapture(label: "gallery-inspector-\(tab.rawValue)") {
                captures.append(image.lastPathComponent)
            }
        }
        workspace.inspectorTab = .artifacts
        return [.make("GL-01", "화면 갤러리 \(captures.count)장 — 육안 검토", status: .unverified,
                      evidence: ["captures": captures.joined(separator: ", ")], startedAt: start)]
    }
}
