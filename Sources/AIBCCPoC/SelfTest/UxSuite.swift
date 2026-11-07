import AppKit

/// UX-01 (diagnostic; user 2026-11-06: resizing and switching views does not
/// feel finished): the transitions a user makes, each captured right after
/// the action and once settled, with every visible terminal's state at both
/// points — whether its surface is attached and its grid matches its view.
/// RS-* only judge the converged end state; this looks at the way there.
@MainActor
struct UxSuite {
    let harness: SelfTestHarness

    func run() async -> [TestResult] {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        Self.trace("ux: start destination=\(workspace.destination.rawValue)")
        workspace.destination = .sessions
        guard let window = harness.window, let recorder = harness.makeRecorderPane(name: "ux") else {
            return [.make("UX-01", "전환 매끄러움 진단", status: .fail, cause: .app, evidence: ["reason": "setup"], startedAt: start)]
        }
        let output = workspace.makePane(title: "output", command: "seq 1 400; exec /bin/zsh -f")
        await harness.install([recorder.pane, output], layout: .double)
        Self.trace("ux: installed")
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorder.log.isReady }
        Self.trace("ux: ready=\(recorder.log.isReady)")
        let original = window.frame
        let log = Log()
        // AIBCC_UX_STRESS=<destination>: switch there and back while resizing,
        // ten times — a crash narrows the constraint loop to one view.
        if ProcessInfo.processInfo.environment["AIBCC_UX_STRESS"] == "measure" {
            for destination in Destination.allCases {
                workspace.destination = destination
                try? await Task.sleep(for: .milliseconds(800))
                let center = CenterView(workspace: workspace, artifacts: harness.artifacts)
                let width = LayoutProbe.minimumWidth(center)
                let height = LayoutProbe.minimumHeight(center, width: 460)
                let inspector = LayoutProbe.minimumHeight(InspectorView(workspace: workspace, artifacts: harness.artifacts), width: 300)
                let sidebar = LayoutProbe.minimumHeight(BarrackSidebar(workspace: workspace), width: 200)
                Self.trace("measure \(destination.rawValue): center min \(Int(width))x\(Int(height)) inspector min h \(Int(inspector)) sidebar min h \(Int(sidebar)) window contentMin \(Int(window.contentMinSize.width))x\(Int(window.contentMinSize.height))")
            }
            return [.make("UX-03", "실창 최소 크기 측정", status: .pass, cause: .app, evidence: [:], startedAt: start)]
        }
        if let name = ProcessInfo.processInfo.environment["AIBCC_UX_STRESS"], let target = Destination(rawValue: name) {
            // The smallest the window's own minimum allows (AIBCC_UX_SMALL_H overrides the height).
            let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
            let height = ProcessInfo.processInfo.environment["AIBCC_UX_SMALL_H"].flatMap(Double.init).map { CGFloat($0) } ?? minimum.height
            let small = NSRect(x: original.minX, y: original.maxY - height, width: minimum.width, height: height)
            Self.trace("stress small=\(Int(small.width))x\(Int(small.height))")
            for round in 0 ..< 10 {
                print("stress \(name) round \(round)")
                fflush(stdout)
                workspace.destination = target
                window.setFrame(small, display: true)
                try? await Task.sleep(for: .milliseconds(250))
                window.setFrame(original, display: true)
                try? await Task.sleep(for: .milliseconds(250))
                workspace.destination = .sessions
                window.setFrame(small, display: true)
                try? await Task.sleep(for: .milliseconds(250))
                window.setFrame(original, display: true)
                try? await Task.sleep(for: .milliseconds(250))
            }
            // After the last round's resize, not before it (Codex build-84 F4).
            Self.trace("stress \(name) done")
            return [.make("UX-02", "전환+크기 변경 반복(\(name))", status: .pass, cause: .app, evidence: [:], startedAt: start)]
        }
        await step(log, "00-agents") {}
        for destination in [Destination.rules, .sessions, .wiki, .sessions, .barrack, .sessions, .history, .sessions] {
            await step(log, "dest-\(destination.rawValue)") { workspace.destination = destination }
        }
        // The smallest window a user can drag to (the content minimum).
        let small = NSRect(x: original.minX, y: original.maxY - 620, width: AppConstants.Layout.minWindowWidth, height: 620)
        let large = NSRect(x: original.minX, y: original.maxY - 1000, width: min(1700, NSScreen.main?.visibleFrame.width ?? 1700), height: 1000)
        await step(log, "win-small") { window.setFrame(small, display: true) }
        await step(log, "win-large") { window.setFrame(large, display: true) }
        // A drag: many frames in a row, then one look.
        await step(log, "win-drag") {
            for t in stride(from: 0.0, through: 1.0, by: 0.1) {
                let width = large.width + (original.width - large.width) * t
                let height = large.height + (original.height - large.height) * t
                window.setFrame(NSRect(x: original.minX, y: original.maxY - height, width: width, height: height), display: true)
            }
        }
        await step(log, "inspector-off") { workspace.isArtifactPanelVisible = false }
        await step(log, "inspector-on") { workspace.isArtifactPanelVisible = true }
        await step(log, "layout-quad") { workspace.setLayout(.quad) }
        await step(log, "layout-single") { workspace.setLayout(.single) }
        await step(log, "layout-double") { workspace.setLayout(.double) }
        await step(log, "dest-rules-small") {
            workspace.destination = .rules
            window.setFrame(small, display: true)
        }
        await step(log, "dest-agents-back") { workspace.destination = .sessions }
        let widest = await wideOutputsOnSmallWindow(window, start)
        window.setFrame(original, display: true)
        return [.make("UX-01", "화면 전환·창 크기·패널·분할 직후와 안정 후 캡처 + 터미널 상태(육안 검토용 진단)",
                      status: .unverified, cause: .app,
                      evidence: ["steps": log.lines.joined(separator: "\n"), "unsettled_after_1s": "\(log.unsettled)",
                                 "captures": log.captures.joined(separator: ",")],
                      startedAt: start), widest]
    }

    /// LY-02b (Codex build-84 review F2): Outputs widened to its maximum on
    /// a minimum-size window still leaves the terminals their reserve.
    private func wideOutputsOnSmallWindow(_ window: NSWindow, _ start: ContinuousClock.Instant) async -> TestResult {
        let workspace = harness.workspace
        let key = AppConstants.Layout.outputsWidthKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        workspace.destination = .sessions
        workspace.isArtifactPanelVisible = true
        UserDefaults.standard.set(Double(AppConstants.Layout.outputsMaxWidth), forKey: key)
        let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - minimum.height, width: minimum.width, height: minimum.height),
                        display: true)
        try? await Task.sleep(for: .milliseconds(800))
        let visible = workspace.panes.prefix(workspace.layout.paneCount).compactMap { $0.probeView }
        let span = visible.map { $0.convert($0.bounds, to: nil) }.reduce(CGRect.null) { $0.union($1) }
        let columns = workspace.panes.first?.state.surfaceSize.map { Int($0.columns) } ?? 0
        let ok = span.width >= AppConstants.Layout.centerReserveWidth - 20
        if let url = await harness.requestCapture(label: "ux-outputs-wide-min") { _ = url }
        return .make("LY-02b", "최소 창 + Outputs 최대: 터미널 영역 ≥ \(Int(AppConstants.Layout.centerReserveWidth))pt",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["window": "\(Int(minimum.width))x\(Int(minimum.height))", "terminal_span": "\(Int(span.width))",
                                "first_pane_columns": "\(columns)"], startedAt: start)
    }

    static func trace(_ line: String) {
        print(line)
        fflush(stdout)
    }

    private final class Log {
        var lines: [String] = []
        var captures: [String] = []
        var unsettled = 0
    }

    private func step(_ log: Log, _ label: String, _ action: () -> Void) async {
        action()
        try? await Task.sleep(for: .milliseconds(120))
        let early = snapshot()
        if let url = await harness.requestCapture(label: "ux-\(label)-a", settled: false) { log.captures.append(url.lastPathComponent) }
        try? await Task.sleep(for: .milliseconds(900))
        let late = snapshot()
        if let url = await harness.requestCapture(label: "ux-\(label)-b") { log.captures.append(url.lastPathComponent) }
        if late.contains("MISMATCH") || late.contains("DETACHED") { log.unsettled += 1 }
        log.lines.append("\(label): after \(early) | settled \(late)")
    }

    /// Each visible pane: grid, view size, and whether they agree.
    private func snapshot() -> String {
        let workspace = harness.workspace
        let visible = workspace.panes.prefix(workspace.layout.paneCount)
        return visible.map { pane -> String in
            guard let view = pane.probeView, let window = view.window else { return "\(pane.title)=DETACHED" }
            guard let grid = pane.state.surfaceSize else { return "\(pane.title)=NOSIZE" }
            let scale = window.backingScaleFactor
            let agrees = abs(CGFloat(grid.widthPixels) - view.bounds.width * scale) <= 2
                && abs(CGFloat(grid.heightPixels) - view.bounds.height * scale) <= 2
            return "\(pane.title)=\(grid.columns)x\(grid.rows)\(agrees ? "" : " MISMATCH view \(Int(view.bounds.width))x\(Int(view.bounds.height))")"
        }.joined(separator: " ")
    }
}
