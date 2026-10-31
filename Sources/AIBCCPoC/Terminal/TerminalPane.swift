import Foundation
import GhosttyTerminal

/// One terminal surface hosted in the grid. Ghostty owns the PTY (`.exec`
/// backend, see docs/spikes/pty-ownership.md).
///
/// The pane strongly owns its native view: the surface (and the child
/// process) lives exactly as long as that view, so SwiftUI re-creating its
/// representable must hand back the same instance instead of a fresh one.
@MainActor
final class TerminalPane: Identifiable {
    let id: UUID
    let title: String
    let state: TerminalViewState
    private var ownedView: ProbeTerminalView?

    var probeView: ProbeTerminalView? { ownedView }

    init(
        controller: TerminalController,
        title: String,
        workingDirectory: String?,
        command: String? = nil,
        extraEnvironment: [String: String] = [:]
    ) {
        let paneID = UUID()
        let viewState = TerminalViewState(controller: controller)
        viewState.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: workingDirectory,
            envVars: Self.environment(paneID: paneID, extra: extraEnvironment),
            command: command
        )
        id = paneID
        self.title = title
        state = viewState
        viewState.makePlatformView = { [weak self] in
            self?.platformView() ?? ProbeTerminalView(frame: .zero)
        }
    }

    private func platformView() -> ProbeTerminalView {
        if let ownedView { return ownedView }
        let view = ProbeTerminalView(frame: .zero)
        ownedView = view
        return view
    }

    /// GUI apps launched from Finder/`open` often have no LANG; a non-UTF-8
    /// child locale breaks Korean input in shells (aibcc 2026-05 incident).
    private static func environment(paneID: UUID, extra: [String: String]) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment[AppConstants.Environment.lang]
        let base = [
            AppConstants.Environment.paneID: paneID.uuidString,
            AppConstants.Environment.lang: inherited ?? AppConstants.Environment.fallbackLocale,
        ]
        return base.merging(extra) { _, override in override }
    }
}
