import AppKit
import GhosttyTerminal

/// Shared plumbing for the self-test suites: fixture panes, waiting, focus,
/// and cell-to-window coordinate math.
@MainActor
struct SelfTestHarness {
    let workspace: WorkspaceModel
    let artifacts: ArtifactStore
    let outputDirectory: URL

    var window: NSWindow? {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey }
    }

    var fixturesDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(AppConstants.Paths.fixturesDirectory, isDirectory: true)
    }

    // MARK: - Fixture panes

    struct RecorderPane {
        let pane: TerminalPane
        let log: RecorderLog
    }

    func makeRecorderPane(name: String, environment: [String: String] = [:]) -> RecorderPane? {
        guard let fixtures = fixturesDirectory else { return nil }
        let log = RecorderLog.makeTemporary(name: name)
        let script = fixtures.appendingPathComponent(AppConstants.Paths.recorderScript).path
        let command = [AppConstants.Paths.python, script, log.url.path].map(shellQuote).joined(separator: " ")
        let pane = workspace.makePane(title: "recorder-\(name)", command: command, environment: environment)
        return RecorderPane(pane: pane, log: log)
    }

    func makeScriptPane(name: String, script: String, readyFile: URL, environment: [String: String] = [:]) -> TerminalPane? {
        guard let fixtures = fixturesDirectory else { return nil }
        let path = fixtures.appendingPathComponent(script).path
        let command = [AppConstants.Paths.shell, path].map(shellQuote).joined(separator: " ")
        let env = environment.merging([AppConstants.Environment.readyFile: readyFile.path]) { $1 }
        return workspace.makePane(title: name, command: command, environment: env)
    }

    func install(_ panes: [TerminalPane], layout: PaneLayout) async {
        workspace.replacePanes(panes, layout: layout)
        _ = await waitUntil(AppConstants.SelfTest.readyTimeout) {
            panes.allSatisfy { $0.probeView != nil && $0.state.surfaceSize != nil }
        }
    }

    // MARK: - Waiting

    /// Polls `condition` until true or timeout. Returns whether it held.
    @discardableResult
    func waitUntil(_ timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: AppConstants.SelfTest.pollInterval)
        }
        return condition()
    }

    func pause(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }

    /// Waits until the recorder stops receiving new bytes for `stableWindow`.
    func settledBytes(_ log: RecorderLog, since mark: Int, expectingAtLeast count: Int = 1) async -> [UInt8] {
        _ = await waitUntil(AppConstants.SelfTest.settleTimeout) { log.bytes(since: mark).count >= count }
        var previous = log.bytes(since: mark)
        while true {
            await pause(AppConstants.SelfTest.stableWindow)
            let current = log.bytes(since: mark)
            if current == previous { return current }
            previous = current
        }
    }

    // MARK: - Focus & geometry

    @discardableResult
    func focus(_ pane: TerminalPane) -> Bool {
        guard let window, let view = pane.probeView else { return false }
        window.makeKeyAndOrderFront(nil)
        return window.makeFirstResponder(view)
    }

    /// Window-space point at the center (or `fraction` across) of a cell.
    func windowPoint(row: Int, column: Int, in pane: TerminalPane, fraction: CGFloat = 0.5) -> NSPoint? {
        guard let view = pane.probeView, let grid = pane.state.surfaceSize else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let cellWidth = CGFloat(grid.cellWidthPixels) / scale
        let cellHeight = CGFloat(grid.cellHeightPixels) / scale
        let x = CGFloat(AppConstants.Terminal.paddingX) + (CGFloat(column) + fraction) * cellWidth
        let yFromTop = CGFloat(AppConstants.Terminal.paddingY) + (CGFloat(row) + 0.5) * cellHeight
        let local = NSPoint(x: x, y: view.bounds.height - yFromTop)
        return view.convert(local, to: nil)
    }

    func clearPasteboard() {
        NSPasteboard.general.clearContents()
    }

    var pasteboardString: String? {
        NSPasteboard.general.string(forType: .string)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
