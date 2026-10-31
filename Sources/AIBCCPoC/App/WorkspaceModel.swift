import AppKit
import GhosttyTerminal
import Observation

/// Terminal grid owned by one barrack: its panes, preset and split positions.
struct BarrackGrid {
    var panes: [TerminalPane]
    var layout: PaneLayout
    var splitX: CGFloat
    var splitY: CGFloat
}

/// App-wide state. Each barrack owns its own terminal grid so the selected
/// barrack, the terminals in the center and the artifacts on the right always
/// share one context (Codex runtime review R1). Switching barracks detaches
/// the other grid's views without killing their shells — panes own their
/// views, and Ghostty keeps a surface across detach/reattach.
@MainActor
@Observable
final class WorkspaceModel {
    let controller: TerminalController
    let barracks: [Barrack]

    var selectedBarrackID: Barrack.ID? {
        didSet { activateSelectedGrid() }
    }
    var isArtifactPanelVisible = true
    private(set) var grids: [String: BarrackGrid] = [:]

    init(barracks: [Barrack] = BarrackRegistry.load()) {
        controller = TerminalAppearance.makeController()
        self.barracks = barracks
        selectedBarrackID = barracks.first?.id
        activateSelectedGrid()
    }

    var selectedBarrack: Barrack? {
        barracks.first { $0.id == selectedBarrackID }
    }

    private var gridKey: String { selectedBarrackID ?? "" }
    private var grid: BarrackGrid {
        grids[gridKey] ?? BarrackGrid(panes: [], layout: .single, splitX: 0.5, splitY: 0.5)
    }

    var panes: [TerminalPane] { grid.panes }
    var layout: PaneLayout { grid.layout }
    var splitX: CGFloat { grid.splitX }
    var splitY: CGFloat { grid.splitY }

    /// Switching presets keeps existing panes (and their shells) alive, only
    /// appends missing ones, and stops drawing panes that are parked.
    func setLayout(_ newLayout: PaneLayout) {
        let current = grid
        let missing = newLayout.paneCount - current.panes.count
        let panes = missing > 0
            ? current.panes + makeShellPanes(count: missing, startingAt: current.panes.count)
            : current.panes
        store(BarrackGrid(panes: panes, layout: newLayout, splitX: current.splitX, splitY: current.splitY))
    }

    func setSplit(x: CGFloat? = nil, y: CGFloat? = nil) {
        let range = AppConstants.Layout.splitRatioRange
        let clamp = { (value: CGFloat) in min(max(value, range.lowerBound), range.upperBound) }
        let current = grid
        store(BarrackGrid(panes: current.panes, layout: current.layout,
                          splitX: x.map(clamp) ?? current.splitX,
                          splitY: y.map(clamp) ?? current.splitY))
    }

    /// Self-test hook: replace the current barrack's grid with fixture panes.
    func replacePanes(_ newPanes: [TerminalPane], layout newLayout: PaneLayout) {
        let current = grid
        store(BarrackGrid(panes: newPanes, layout: newLayout, splitX: current.splitX, splitY: current.splitY))
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

    /// Replaces a pane with a fresh shell in the same slot (used by the
    /// "새 셸" button on an exited pane and by surface close requests).
    func restartPane(id paneID: UUID) {
        let current = grid
        guard let index = current.panes.firstIndex(where: { $0.id == paneID }) else { return }
        let replacement = makePane(title: "shell \(index + 1)")
        let panes = current.panes.enumerated().map { offset, pane in offset == index ? replacement : pane }
        store(BarrackGrid(panes: panes, layout: current.layout, splitX: current.splitX, splitY: current.splitY))
    }

    /// Writes every pane's recorded input-method callbacks to a JSON fixture.
    /// Used after the human IME checklist so a real keyboard session can be
    /// replayed later as an `imeCallbackContract` test.
    func exportInputCallLogs() -> URL? {
        let allPanes = grids.values.flatMap(\.panes)
        let logs = Dictionary(
            allPanes.map { ("\($0.title)-\($0.id.uuidString.prefix(8))", $0.probeView?.callLog ?? []) },
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

    // MARK: - Private

    private func activateSelectedGrid() {
        if grids[gridKey] == nil {
            store(BarrackGrid(panes: makeShellPanes(count: 1, startingAt: 0), layout: .single, splitX: 0.5, splitY: 0.5))
        } else {
            updateSurfaceVisibility()
        }
    }

    private func store(_ newGrid: BarrackGrid) {
        grids = grids.merging([gridKey: newGrid]) { _, new in new }
        updateSurfaceVisibility()
    }

    /// Ghostty asked to close the surface after its process ended. Close
    /// requests for live processes are ignored in the PoC.
    private func handleClose(paneID: UUID, processAlive: Bool) {
        guard !processAlive else { return }
        restartPane(id: paneID)
    }

    /// Only the selected barrack's visible panes draw; keyboard focus never
    /// stays on a parked pane (Codex review r2 #2).
    private func updateSurfaceVisibility() {
        let visible = Set(grid.panes.prefix(grid.layout.paneCount).map(\.id))
        for pane in grids.values.flatMap(\.panes) {
            pane.state.isSurfaceVisible = visible.contains(pane.id)
        }
        let parked = grid.panes.dropFirst(grid.layout.paneCount)
        guard let focusedParked = parked.first(where: { pane in
            guard let view = pane.probeView, let responder = view.window?.firstResponder as? NSView else { return false }
            return responder === view || responder.isDescendant(of: view)
        }), let target = grid.panes.first?.probeView else { return }
        if focusedParked.probeView?.hasMarkedText() == true { focusedParked.probeView?.unmarkText() }
        target.window?.makeFirstResponder(target)
    }

    private func makeShellPanes(count: Int, startingAt offset: Int) -> [TerminalPane] {
        (0..<max(count, 0)).map { index in
            makePane(title: "shell \(offset + index + 1)")
        }
    }
}
