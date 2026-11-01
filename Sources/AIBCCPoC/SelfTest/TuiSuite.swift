import AppKit

/// RS-06 (PoC half): Claude Code's TUI through the layout changes that
/// reflow a terminal — window shrink/grow, the artifact panel, a split —
/// with a capture after each step for residue review. The reference half
/// (aibcc v1.6.1, Terminal, iTerm) runs through scripts/run-bench.py rs06.
/// Explicit suite (`--selftest-only=rs06`); starts a real `claude` in
/// /tmp/aibcc-rs06 (no prompt is sent) and needs scripts/capture-watcher.sh.
@MainActor
struct TuiSuite {
    let harness: SelfTestHarness
    private static let directory = "/tmp/aibcc-rs06"
    private static let startup: Duration = .seconds(8)
    private static let settle: Duration = .milliseconds(1500)

    func run() async -> [TestResult] {
        let start = ContinuousClock.now
        let claude = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/claude")
        try? FileManager.default.createDirectory(atPath: Self.directory, withIntermediateDirectories: true)
        guard let window = harness.window, FileManager.default.isExecutableFile(atPath: claude)
        else {
            return [.make("RS-06-poc", "PoC에서 Claude TUI 리사이즈 캡처", status: .unverified,
                          evidence: ["reason": "claude not installed or no window"], startedAt: start)]
        }
        // Ghostty execs `command` without a shell, so `cd … && …` needs one;
        // a login shell also gives claude the user's PATH, as when typed.
        let pane = harness.workspace.makePane(
            title: "claude", command: "/bin/zsh -lc 'cd \(Self.directory) && exec \(claude)'"
        )
        await harness.install([pane], layout: .single)
        harness.focus(pane)
        await harness.pause(Self.startup)
        var captures = [await capture("0-start", pane)]
        // The first run in the folder asks to trust it, with "No, exit"
        // selected: move to "Yes" first. On a trusted folder both keys are
        // no-ops on the empty prompt.
        EventSynthesizer.press(EventSynthesizer.downArrow, in: window)
        await harness.pause(.milliseconds(300))
        EventSynthesizer.press(EventSynthesizer.returnKey, in: window)
        await harness.pause(.seconds(3))
        captures.append(await capture("1-ready", pane))
        captures += await layoutSequence(pane, window)
        let processBeforeExit = pane.processID.map { Self.commandName(of: $0) } ?? "none"
        let keptBeforeExit = harness.workspace.panes.contains { $0.id == pane.id } && !pane.hasExited
        if let ctrlC = EventSynthesizer.control("c") {
            EventSynthesizer.press(ctrlC, in: window)
            await harness.pause(.milliseconds(400))
            EventSynthesizer.press(ctrlC, in: window)
        }
        let taken = captures.compactMap { $0 }
        // The captures only mean something if claude really ran in this
        // pane the whole time (a failed command gets replaced by a shell).
        let stillInGrid = keptBeforeExit
        let process = processBeforeExit
        let ranClaude = stillInGrid && (process.contains("claude") || process.contains("2.1."))
        return [.make("RS-06-poc", "PoC에서 Claude TUI 레이아웃 변경 \(taken.count)장 캡처 — 잔해 검토 필요",
                      status: ranClaude ? .unverified : .fail, cause: .app,
                      evidence: ["captures": taken.joined(separator: " | "), "pane_kept": "\(stillInGrid)",
                                 "process_before_exit": process], startedAt: start)]
    }

    private func layoutSequence(_ pane: TerminalPane, _ window: NSWindow) async -> [String?] {
        let workspace = harness.workspace
        let original = window.frame
        let steps: [(String, () -> Void)] = [
            ("2-window-small", { window.setContentSize(AppConstants.SelfTest.resizeSmallSize) }),
            ("3-window-large", { window.setContentSize(AppConstants.SelfTest.resizeLargeSize) }),
            ("4-panel-hidden", { workspace.isArtifactPanelVisible = false }),
            ("5-panel-shown", { workspace.isArtifactPanelVisible = true }),
            ("6-split-two", { workspace.setLayout(.double) }),
            ("7-split-one", { workspace.setLayout(.single) }),
            ("8-window-small", { window.setContentSize(AppConstants.SelfTest.resizeSmallSize) }),
            ("9-window-restored", { window.setFrame(original, display: true) }),
        ]
        var captures: [String?] = []
        for (label, change) in steps {
            change()
            await harness.pause(Self.settle)
            captures.append(await capture(label, pane))
        }
        captures.append(await rapidDrag(to: AppConstants.SelfTest.resizeSmallSize, label: "10-drag-narrow", pane, window))
        captures.append(await rapidDrag(to: AppConstants.SelfTest.resizeLargeSize, label: "11-drag-wide", pane, window))
        window.setFrame(original, display: true)
        return captures
    }

    /// Width changes like a mouse drag (20 steps, 30 ms apart) — where
    /// reflow residue usually shows — captured once the drag stops.
    private func rapidDrag(to target: CGSize, label: String, _ pane: TerminalPane, _ window: NSWindow) async -> String? {
        let from = window.contentLayoutRect.size
        for step in 1...20 {
            let t = CGFloat(step) / 20
            window.setContentSize(CGSize(width: from.width + (target.width - from.width) * t,
                                         height: from.height + (target.height - from.height) * t))
            await harness.pause(.milliseconds(30))
        }
        await harness.pause(Self.settle)
        return await capture(label, pane)
    }

    private static func commandName(of pid: pid_t) -> String {
        let pipe = Pipe()
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "command=", "-p", "\(pid)"]
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return "unknown" }
        ps.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Records what the capture must show (grid) next to its file name.
    private func capture(_ label: String, _ pane: TerminalPane) async -> String? {
        let grid = pane.state.surfaceSize.map { "\($0.columns)x\($0.rows)" } ?? "nil"
        guard let image = await harness.requestCapture(label: "rs06-\(label)") else { return nil }
        return "\(image.lastPathComponent) grid=\(grid)"
    }
}
