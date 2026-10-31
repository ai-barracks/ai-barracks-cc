import AppKit
import GhosttyTerminal
import Observation

/// App-wide state: registered barracks, the terminal grid, and the artifact
/// panel. Collections are replaced, never mutated in place.
@MainActor
@Observable
final class WorkspaceModel {
    let controller: TerminalController
    let barracks: [Barrack]

    var selectedBarrackID: Barrack.ID?
    var isArtifactPanelVisible = true
    private(set) var panes: [TerminalPane] = []
    private(set) var layout: PaneLayout = .single
    /// Split positions as fractions of the grid (dragged via dividers).
    private(set) var splitX: CGFloat = 0.5
    private(set) var splitY: CGFloat = 0.5

    init(barracks: [Barrack] = BarrackRegistry.load()) {
        controller = TerminalAppearance.makeController()
        self.barracks = barracks
        selectedBarrackID = barracks.first?.id
        panes = makeShellPanes(count: layout.paneCount, startingAt: 0)
    }

    var selectedBarrack: Barrack? {
        barracks.first { $0.id == selectedBarrackID }
    }

    /// Switching presets keeps existing panes (and their shells) alive, only
    /// appends missing ones, and stops drawing panes that are parked.
    func setLayout(_ newLayout: PaneLayout) {
        let missing = newLayout.paneCount - panes.count
        if missing > 0 {
            panes = panes + makeShellPanes(count: missing, startingAt: panes.count)
        }
        layout = newLayout
        updateSurfaceVisibility()
    }

    func setSplit(x: CGFloat? = nil, y: CGFloat? = nil) {
        let range = AppConstants.Layout.splitRatioRange
        if let x { splitX = min(max(x, range.lowerBound), range.upperBound) }
        if let y { splitY = min(max(y, range.lowerBound), range.upperBound) }
    }

    /// Self-test hook: replace the whole grid with fixture panes.
    func replacePanes(_ newPanes: [TerminalPane], layout newLayout: PaneLayout) {
        panes = newPanes
        layout = newLayout
        updateSurfaceVisibility()
    }

    func makePane(
        title: String,
        command: String? = nil,
        environment: [String: String] = [:]
    ) -> TerminalPane {
        let pane = TerminalPane(
            controller: controller,
            title: title,
            workingDirectory: selectedBarrack?.path,
            command: command,
            extraEnvironment: environment
        )
        let paneID = pane.id
        pane.state.onClose = { [weak self] processAlive in
            self?.handleClose(paneID: paneID, processAlive: processAlive)
        }
        return pane
    }

    /// Writes every pane's recorded input-method callbacks to a JSON fixture.
    /// Used after the human IME checklist so a real keyboard session can be
    /// replayed later as an `imeCallbackContract` test.
    func exportInputCallLogs() -> URL? {
        let logs = Dictionary(
            panes.map { ($0.title, $0.probeView?.callLog ?? []) },
            uniquingKeysWith: { first, _ in first }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(logs) else { return nil }
        let directory = URL(
            fileURLWithPath: (AppConstants.SelfTest.defaultOutputDirectory as NSString).expandingTildeInPath,
            isDirectory: true
        ).deletingLastPathComponent()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = directory.appendingPathComponent("ime-calllog-\(stamp).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    /// Replaces a pane with a fresh shell in the same slot (used by the
    /// "새 셸" button on an exited pane and by surface close requests).
    func restartPane(id paneID: UUID) {
        guard let index = panes.firstIndex(where: { $0.id == paneID }) else { return }
        let replacement = makePane(title: "shell \(index + 1)")
        panes = panes.enumerated().map { offset, pane in offset == index ? replacement : pane }
        updateSurfaceVisibility()
    }

    /// Ghostty asked to close the surface after its process ended. Close
    /// requests for live processes are ignored in the PoC.
    private func handleClose(paneID: UUID, processAlive: Bool) {
        guard !processAlive else { return }
        restartPane(id: paneID)
    }

    /// Parked panes stop drawing, and keyboard focus never stays on a parked
    /// pane (Codex review r2 #2): it moves to the first visible pane.
    private func updateSurfaceVisibility() {
        for (index, pane) in panes.enumerated() {
            pane.state.isSurfaceVisible = index < layout.paneCount
        }
        let parked = panes.dropFirst(layout.paneCount)
        guard let focusedParked = parked.first(where: { pane in
            guard let view = pane.probeView, let responder = view.window?.firstResponder as? NSView else { return false }
            return responder === view || responder.isDescendant(of: view)
        }), let target = panes.first?.probeView else { return }
        if focusedParked.probeView?.hasMarkedText() == true { focusedParked.probeView?.unmarkText() }
        target.window?.makeFirstResponder(target)
    }

    private func makeShellPanes(count: Int, startingAt offset: Int) -> [TerminalPane] {
        (0..<max(count, 0)).map { index in
            makePane(title: "shell \(offset + index + 1)")
        }
    }
}
