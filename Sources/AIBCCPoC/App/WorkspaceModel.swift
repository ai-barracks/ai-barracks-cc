import Foundation
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

    init(barracks: [Barrack] = BarrackRegistry.load()) {
        controller = TerminalAppearance.makeController()
        self.barracks = barracks
        selectedBarrackID = barracks.first?.id
        panes = makeShellPanes(count: layout.paneCount, startingAt: 0)
    }

    var selectedBarrack: Barrack? {
        barracks.first { $0.id == selectedBarrackID }
    }

    /// Switching presets keeps existing panes (and their shells) alive and
    /// only appends the missing ones.
    func setLayout(_ newLayout: PaneLayout) {
        let missing = newLayout.paneCount - panes.count
        if missing > 0 {
            panes = panes + makeShellPanes(count: missing, startingAt: panes.count)
        }
        layout = newLayout
    }

    /// Self-test hook: replace the whole grid with fixture panes.
    func replacePanes(_ newPanes: [TerminalPane], layout newLayout: PaneLayout) {
        panes = newPanes
        layout = newLayout
    }

    func makePane(
        title: String,
        command: String? = nil,
        environment: [String: String] = [:]
    ) -> TerminalPane {
        TerminalPane(
            controller: controller,
            title: title,
            workingDirectory: selectedBarrack?.path,
            command: command,
            extraEnvironment: environment
        )
    }

    /// Writes every pane's recorded input-method callbacks to a JSON fixture.
    /// Used after the human IME checklist so a real keyboard session can be
    /// replayed later as an `imeCallbackContract` test.
    func exportInputCallLogs() -> URL? {
        let logs = panes.reduce(into: [String: [InputCallRecord]]()) { result, pane in
            result[pane.title] = pane.probeView?.callLog ?? []
        }
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
            try data.write(to: file)
            return file
        } catch {
            return nil
        }
    }

    private func makeShellPanes(count: Int, startingAt offset: Int) -> [TerminalPane] {
        (0..<max(count, 0)).map { index in
            makePane(title: "shell \(offset + index + 1)")
        }
    }
}
