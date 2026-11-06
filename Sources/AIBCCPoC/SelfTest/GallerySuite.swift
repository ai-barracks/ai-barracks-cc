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
        if let window = harness.window {
            workspace.isPalettePresented = true
            await harness.pause(.seconds(1))
            EventSynthesizer.type("ghostty", in: window)
            await harness.pause(.seconds(2))
            if let image = await harness.requestCapture(label: "gallery-palette") { captures.append(image.lastPathComponent) }
            workspace.isPalettePresented = false
            await harness.pause(.milliseconds(500))
        }
        if let barrack = workspace.selectedBarrack {
            for name in ["RULES.md", "SOUL.md", "GROWTH.md", "agent.yaml"] {
                workspace.destination = .rules
                await harness.pause(.milliseconds(500))
                workspace.pendingDocument = barrack.url.appendingPathComponent(name)
                workspace.pendingStructuredEdit = true
                await harness.pause(.seconds(2))
                if let image = await harness.requestCapture(label: "gallery-form-\(name)") { captures.append(image.lastPathComponent) }
                workspace.pendingStructuredEdit = false
            }
        }
        workspace.destination = .skills
        await harness.pause(.seconds(1))
        workspace.pendingStructuredEdit = true
        await harness.pause(.seconds(2))
        if let image = await harness.requestCapture(label: "gallery-skill-editor") { captures.append(image.lastPathComponent) }
        workspace.pendingStructuredEdit = false
        workspace.destination = .history
        await harness.pause(.seconds(2))
        if let image = await harness.requestCapture(label: "gallery-history") { captures.append(image.lastPathComponent) }
        workspace.destination = .sessions
        return [.make("GL-01", "화면 갤러리 \(captures.count)장 — 육안 검토", status: .unverified,
                      evidence: ["captures": captures.joined(separator: ", ")], startedAt: start)]
    }
}
