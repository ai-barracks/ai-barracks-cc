import AppKit

/// A walk through the app as a user would use it, for visual review of
/// window and drawing bugs (explicit suite `--selftest-only=walk`; needs
/// scripts/capture-watcher.sh). Each terminal redraws a frame — its name,
/// its size, a rule along the top and the bottom row — so a clipped,
/// stale or misplaced surface shows in the picture. Every step also
/// records whether each visible terminal's frame lies inside the window
/// and clear of the others.
@MainActor
struct WalkSuite {
    let harness: SelfTestHarness
    private var workspace: WorkspaceModel { harness.workspace }

    func run() async -> [TestResult] {
        let start = ContinuousClock.now
        guard let window = harness.window, let screen = window.screen ?? NSScreen.main else {
            return [.make("WK-00", "사용 흐름 캡처", status: .unverified, evidence: ["reason": "no window"], startedAt: start)]
        }
        var shots: [String] = []
        var problems: [String] = []
        let shoot = { (label: String) async in
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            await harness.pause(.milliseconds(1400))
            problems += geometryProblems(in: window).map { "\(label): \($0)" }
            if let url = await harness.requestCapture(label: "walk-\(label)") { shots.append(url.lastPathComponent) }
        }
        let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        let full = screen.visibleFrame
        let sizes: [(String, NSSize)] = [
            ("min", minimum), ("mid", NSSize(width: min(1280, full.width), height: min(800, full.height))), ("full", full.size),
        ]
        let resize = { (size: NSSize) async in
            window.setFrame(NSRect(x: full.minX, y: full.maxY - size.height, width: size.width, height: size.height), display: true)
            await harness.pause(.milliseconds(600))
        }
        workspace.destination = .sessions
        workspace.isArtifactPanelVisible = true
        UserDefaults.standard.set(true, forKey: AppConstants.Terminal.agentListShownKey)
        let panes = (1 ... 6).compactMap { workspace.runInPane(title: "walk \($0)", command: Self.frameCommand("walk \($0)")) }
        await harness.pause(.seconds(2))

        for (name, size) in sizes {
            await resize(size)
            workspace.setLayout(.quad)
            await shoot("\(name)-quad-list-outputs")
            UserDefaults.standard.set(false, forKey: AppConstants.Terminal.agentListShownKey)
            await shoot("\(name)-quad-nolist")
            UserDefaults.standard.set(true, forKey: AppConstants.Terminal.agentListShownKey)
            workspace.isArtifactPanelVisible = false
            await shoot("\(name)-quad-list-nooutputs")
            for layout in [PaneLayout.single, .double, .twoRows] {
                workspace.setLayout(layout)
                await shoot("\(name)-\(layout.rawValue)")
            }
            workspace.isArtifactPanelVisible = true
        }

        // Using it: swap a held terminal in, drag the splits, close one on
        // screen, leave for a document and come back, shake the window.
        await resize(sizes[1].1)
        workspace.setLayout(.quad)
        if let held = workspace.panes.dropFirst(4).first { workspace.show(held.id, inSlot: 1) }
        await shoot("use-swap-slot2")
        workspace.setSplit(x: 0.3, y: 0.7)
        await shoot("use-split-30-70")
        workspace.setSplit(x: 0.5, y: 0.5)
        if let first = workspace.panes.first { workspace.closePane(id: first.id) }
        await shoot("use-closed-slot1")
        workspace.destination = .wiki
        await harness.pause(.milliseconds(800))
        await resize(sizes[0].1)
        workspace.destination = .sessions
        await shoot("use-back-from-wiki-at-min")
        for size in [sizes[2].1, sizes[0].1, sizes[1].1, sizes[2].1, sizes[1].1] {
            window.setFrame(NSRect(x: full.minX, y: full.maxY - size.height, width: size.width, height: size.height), display: true)
            await harness.pause(.milliseconds(120))
        }
        await shoot("use-after-shake")
        if let other = workspace.barracks.first(where: { $0.id != workspace.selectedBarrackID }), let original = workspace.selectedBarrackID {
            workspace.selectedBarrackID = other.id
            await shoot("use-other-barrack-empty")
            workspace.selectedBarrackID = original
            await shoot("use-returned")
        }
        for destination in Destination.allCases where destination != .sessions {
            for (name, size) in sizes.prefix(2) {
                await resize(size)
                workspace.destination = destination
                await shoot("\(destination.rawValue)-\(name)")
            }
        }
        workspace.destination = .sessions
        panes.forEach { workspace.closePane(id: $0.id) }
        await shoot("end-empty")
        return [.make("WK-00", "사용 흐름 캡처 \(shots.count)장 — 육안 검토, 칸 배치 자동 점검",
                      status: problems.isEmpty ? .unverified : .fail, cause: .app,
                      evidence: ["captures": "\(shots.count)", "problems": problems.joined(separator: " | ")], startedAt: start)]
    }

    /// Redraws once a second: name and size, a rule on the first and the
    /// last row, so the surface's true extent is on screen.
    static func frameCommand(_ name: String) -> String {
        let script = "while true; do c=$(tput cols); l=$(tput lines); clear; printf '%*s' \"$c\" '' | tr ' ' '='; "
            + "printf '\\n\(name)  %sx%s\\n' \"$c\" \"$l\"; tput cup $((l-1)) 0; printf '%*s' \"$c\" '' | tr ' ' '#'; sleep 1; done"
        return "/bin/zsh -fc " + AgentLauncher.shellQuote(script)
    }

    /// Visible terminals must have a size, lie inside the window's content
    /// and not overlap each other.
    private func geometryProblems(in window: NSWindow) -> [String] {
        guard workspace.destination == .sessions, let content = window.contentView else { return [] }
        let visible = Array(workspace.panes.prefix(workspace.layout.paneCount))
        var problems: [String] = []
        let frames: [(String, CGRect)] = visible.compactMap { pane in
            guard let view = pane.probeView, view.window != nil else {
                problems.append("\(pane.title) not in window")
                return nil
            }
            return (pane.title, view.convert(view.bounds, to: nil))
        }
        for (title, frame) in frames {
            if frame.width < 40 || frame.height < 40 { problems.append("\(title) tiny \(Int(frame.width))x\(Int(frame.height))") }
            if !content.frame.insetBy(dx: -1, dy: -1).contains(frame) { problems.append("\(title) outside window \(frame.integral)") }
        }
        for (index, first) in frames.enumerated() {
            for second in frames.dropFirst(index + 1) where first.1.insetBy(dx: 1, dy: 1).intersects(second.1) {
                problems.append("\(first.0) overlaps \(second.0)")
            }
        }
        let held = workspace.panes.dropFirst(workspace.layout.paneCount)
        for pane in held where pane.state.isSurfaceVisible { problems.append("\(pane.title) held but drawing") }
        for pane in visible {
            guard let view = pane.probeView, let size = pane.state.surfaceSize else {
                problems.append("\(pane.title) no surface size")
                continue
            }
            if size.columns < 2 || size.rows < 2 { problems.append("\(pane.title) grid \(size.columns)x\(size.rows) in \(Int(view.bounds.width))pt") }
        }
        return problems
    }
}
