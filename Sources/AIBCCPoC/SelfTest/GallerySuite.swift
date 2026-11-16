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
        // AIBCC_GALLERY_FRAME=full: the screen's whole visible frame (how a
        // wide window uses its width, 2026-11-09 feedback).
        if ProcessInfo.processInfo.environment["AIBCC_GALLERY_FRAME"] == "full",
           let window = harness.window, let screen = window.screen ?? NSScreen.main {
            window.setFrame(screen.visibleFrame, display: true)
            await harness.pause(.seconds(1))
        }
        workspace.isArtifactPanelVisible = true
        for destination in Destination.allCases {
            workspace.destination = destination
            // Files with something to look at: a document inside a folder.
            if destination == .files, let barrack = workspace.selectedBarrack {
                let folders = FileTree.children(of: barrack.url, showHidden: false).filter(\.isDirectory)
                let document = folders.lazy.flatMap { FileTree.children(of: $0.url, showHidden: false) }
                    .first { FileTree.kind(of: $0.url) == .markdown }
                if let document { workspace.fileBrowser.open(document.url, in: barrack) }
            }
            await harness.pause(.seconds(2))
            if let image = await harness.requestCapture(label: "gallery-\(destination.rawValue)") {
                captures.append(image.lastPathComponent)
            }
            // The same tree ordered by modified date, newest first.
            if destination == .files {
                UserDefaults.standard.set(FileOrder.Key.modified.rawValue, forKey: AppConstants.Files.sortKeyKey)
                UserDefaults.standard.set(false, forKey: AppConstants.Files.sortAscendingKey)
                await harness.pause(.seconds(1))
                if let image = await harness.requestCapture(label: "gallery-files-by-date") { captures.append(image.lastPathComponent) }
                UserDefaults.standard.removeObject(forKey: AppConstants.Files.sortKeyKey)
                UserDefaults.standard.removeObject(forKey: AppConstants.Files.sortAscendingKey)
            }
        }
        // P01: more terminals than slots, with the agent list beside them.
        // Each titles its screen, as an agent does with what it is on.
        let many = (1 ... 6).compactMap {
            workspace.runInPane(title: "gallery \($0)", command: "printf '\\033]0;%s\\007' '갤러리 작업 \($0) 진행 중'; sleep 120")
        }
        workspace.setLayout(.quad)
        workspace.destination = .sessions
        await harness.pause(.seconds(2))
        if let image = await harness.requestCapture(label: "gallery-agents-many") { captures.append(image.lastPathComponent) }
        // A held terminal brought up: the list keeps its order.
        if let held = workspace.panes.dropFirst(workspace.layout.paneCount).last {
            workspace.selectPane(id: held.id)
            await harness.pause(.seconds(2))
            if let image = await harness.requestCapture(label: "gallery-agents-selected") { captures.append(image.lastPathComponent) }
        }
        many.forEach { workspace.closePane(id: $0.id) }
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
