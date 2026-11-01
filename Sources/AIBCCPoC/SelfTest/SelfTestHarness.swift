import AppKit
import GhosttyTerminal

/// Shared plumbing for the self-test suites: fixture panes, waiting, focus,
/// cell-to-window coordinate math, and window-capture requests.
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

    func makeRecorderPane(
        name: String,
        environment: [String: String] = [:],
        script recorderScript: String = AppConstants.Paths.recorderScript
    ) -> RecorderPane? {
        guard let fixtures = fixturesDirectory else { return nil }
        let log = RecorderLog.makeTemporary(name: name)
        let script = fixtures.appendingPathComponent(recorderScript).path
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

    @discardableResult
    func install(_ panes: [TerminalPane], layout: PaneLayout) async -> Bool {
        workspace.replacePanes(panes, layout: layout)
        return await waitUntil(AppConstants.SelfTest.readyTimeout) {
            panes.prefix(layout.paneCount).allSatisfy { $0.probeView?.window != nil && $0.state.surfaceSize != nil }
        }
    }

    // MARK: - Waiting

    /// Polls `condition` until true or timeout. Returns whether it held.
    @discardableResult
    func waitUntil(_ timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if condition() { return true }
            await pause(AppConstants.SelfTest.pollInterval)
        }
        return condition()
    }

    func pause(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }

    /// Waits until every event posted so far has been dispatched (sentinel
    /// barrier). Returns false if the queue did not drain in time.
    @discardableResult
    func drain() async -> Bool {
        guard let window else { return false }
        let token = EventBarrier.shared.post(windowNumber: window.windowNumber)
        return await waitUntil(AppConstants.SelfTest.settleTimeout) { EventBarrier.shared.isAcknowledged(token) }
    }

    /// Bytes received since `mark` once the stream has been quiet for
    /// `stableWindow`, bounded by `settleTimeout` overall.
    func settledBytes(_ log: RecorderLog, since mark: Int, expectingAtLeast count: Int = 1) async -> [UInt8] {
        await drain()
        let deadline = ContinuousClock.now + AppConstants.SelfTest.settleTimeout
        _ = await waitUntil(AppConstants.SelfTest.settleTimeout) { log.bytes(since: mark).count >= count }
        var previous = log.bytes(since: mark)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            await pause(AppConstants.SelfTest.stableWindow)
            let current = log.bytes(since: mark)
            if current == previous { return current }
            previous = current
        }
        return previous
    }

    // MARK: - Focus & geometry

    @discardableResult
    func focus(_ pane: TerminalPane) -> Bool {
        guard let window, let view = pane.probeView else { return false }
        window.makeKeyAndOrderFront(nil)
        return window.makeFirstResponder(view)
    }

    /// Clicks a cell through the real mouse path (used to switch panes).
    /// Requires the app to be active (see SelfTestRunner).
    func click(row: Int, column: Int, in pane: TerminalPane) async {
        guard let window, let point = windowPoint(row: row, column: column, in: pane) else { return }
        EventSynthesizer.click(at: point, count: 1, in: window)
        await drain()
    }

    func isFirstResponder(_ view: NSView?) -> Bool {
        guard let view, let responder = window?.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
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

    // MARK: - Window capture handshake

    /// Asks scripts/capture-watcher.sh (run outside the app, which already has
    /// screen-capture rights) for a composited window capture. Returns the
    /// PNG path if it appeared in time.
    func requestCapture(label: String) async -> URL? {
        guard let window else { return nil }
        // Convergence is judged on grid/PTY sizes; give the renderer time to
        // present that state before the window server captures it.
        await pause(AppConstants.SelfTest.captureRenderGrace)
        let image = outputDirectory.appendingPathComponent("capture-\(label).png")
        let request = outputDirectory.appendingPathComponent("capture-request-\(label).json")
        let body = "{\"window\": \(window.windowNumber), \"output\": \"\(image.path)\"}\n"
        guard (try? body.write(to: request, atomically: true, encoding: .utf8)) != nil else { return nil }
        let captured = await waitUntil(AppConstants.SelfTest.captureTimeout) {
            FileManager.default.fileExists(atPath: image.path)
        }
        return captured ? image : nil
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
