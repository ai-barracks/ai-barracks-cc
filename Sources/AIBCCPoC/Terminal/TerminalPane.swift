import Foundation
import GhosttyTerminal

/// One terminal surface hosted in the grid. Ghostty owns the PTY (`.exec`
/// backend, see docs/spikes/pty-ownership.md).
@MainActor
final class TerminalPane: Identifiable {
    let id: UUID
    let title: String
    let state: TerminalViewState

    var probeView: ProbeTerminalView? {
        state.attachedPlatformView as? ProbeTerminalView
    }

    init(
        controller: TerminalController,
        title: String,
        workingDirectory: String?,
        command: String? = nil,
        extraEnvironment: [String: String] = [:]
    ) {
        let paneID = UUID()
        let viewState = TerminalViewState(controller: controller)
        viewState.makePlatformView = { ProbeTerminalView(frame: .zero) }
        viewState.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: workingDirectory,
            envVars: Self.environment(paneID: paneID, extra: extraEnvironment),
            command: command
        )
        id = paneID
        self.title = title
        state = viewState
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
