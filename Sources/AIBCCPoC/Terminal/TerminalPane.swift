import Foundation
import GhosttyTerminal
import Observation

/// Who owns a pane's PTY.
enum PaneBackend {
    /// Ghostty spawns and owns the child (dies with the app).
    case exec
    /// AIBCCPtyDaemon owns it; `attach` reconnects to a running session.
    case daemon(DaemonBackend, sessionID: UUID, attach: Bool)
}

/// One terminal surface hosted in the grid (docs/spikes/pty-ownership.md).
///
/// The pane strongly owns its native view: the surface (and, with the exec
/// backend, the child process) lives exactly as long as that view, so
/// SwiftUI re-creating its representable must hand back the same instance
/// instead of a fresh one.
@MainActor
@Observable
final class TerminalPane: Identifiable {
    let id: UUID
    let title: String
    let state: TerminalViewState
    /// Daemon link (daemon backend only).
    let remote: DaemonSession?
    /// The child exited; the pane keeps its final output on screen.
    private(set) var hasExited = false
    private(set) var failure: String?
    @ObservationIgnored private var ownedView: ProbeTerminalView?
    @ObservationIgnored private var exitMonitor: ProcessExitMonitor?
    @ObservationIgnored private var remotePID: pid_t?
    @ObservationIgnored private var isSettlingReplay = false

    var probeView: ProbeTerminalView? { ownedView }
    var monitoredPID: pid_t? { exitMonitor?.pid ?? remotePID }
    var isChildGone: Bool { exitMonitor?.isGone ?? false }
    /// Root process of the pane: the daemon's child, or Ghostty's.
    var processID: pid_t? { remote == nil ? probeView?.foregroundPid : remotePID }

    init(
        controller: TerminalController,
        title: String,
        workingDirectory: String?,
        command: String? = nil,
        extraEnvironment: [String: String] = [:],
        backend: PaneBackend = .exec
    ) {
        let paneID = UUID()
        let environment = Self.environment(paneID: paneID, extra: extraEnvironment)
        let viewState = TerminalViewState(controller: controller)
        let relay = PaneEventRelay()
        switch backend {
        case .exec:
            remote = nil
            viewState.configuration = TerminalSurfaceOptions(
                backend: .exec, workingDirectory: workingDirectory, envVars: environment, command: command
            )
        case let .daemon(daemon, sessionID, attach):
            let start: DaemonSession.Start = attach ? .attach : .create(
                DaemonLaunch.request(command: command, workingDirectory: workingDirectory, environment: environment)
            )
            let deliver: @Sendable (DaemonSession.Event) -> Void = { event in
                DispatchQueue.main.async { MainActor.assumeIsolated { relay.pane?.handle(event) } }
            }
            // A daemon that died (crash, manual kill) is started again once.
            remote = DaemonSession(id: sessionID, socketPath: daemon.socketPath, start: start, onEvent: deliver)
                ?? (daemon.ensureRunning()
                    ? DaemonSession(id: sessionID, socketPath: daemon.socketPath, start: start, onEvent: deliver)
                    : nil)
            if let remote {
                viewState.configuration = TerminalSurfaceOptions(backend: .inMemory(remote.terminal))
            }
        }
        id = paneID
        self.title = title
        state = viewState
        viewState.makePlatformView = { [weak self] in
            self?.platformView() ?? ProbeTerminalView(frame: .zero)
        }
        relay.pane = self
        if case .daemon = backend, remote == nil {
            failure = "PTY 데몬에 연결할 수 없습니다"
            hasExited = true
        }
    }

    /// Ends a daemon session for good (the pane left its grid). Exec panes
    /// end with their view, as before.
    func terminate() {
        remote?.kill()
    }

    isolated deinit {
        // Safety net only: SwiftUI may hold a removed pane for a while, so
        // the workspace terminates removed panes explicitly. An app quit
        // never runs this, so daemon sessions survive the quit.
        remote?.kill()
    }

    /// Starts watching the surface's child once Ghostty has spawned it
    /// (exec), and settles a pending attach replay once a surface exists.
    func startExitMonitorIfNeeded() {
        if remote != nil {
            settleReplayIfNeeded()
            return
        }
        guard exitMonitor == nil, !hasExited, let pid = probeView?.foregroundPid, pid > 0 else { return }
        exitMonitor = ProcessExitMonitor(pid: pid) { [weak self] in self?.childDidExit() }
    }

    private func childDidExit() {
        // A login/exec chain can hand the terminal to a new process; follow
        // it instead of declaring the pane dead.
        if remote == nil, let next = probeView?.foregroundPid, next > 0, next != exitMonitor?.pid, kill(next, 0) == 0 {
            exitMonitor = ProcessExitMonitor(pid: next) { [weak self] in self?.childDidExit() }
            return
        }
        hasExited = true
    }

    private func handle(_ event: DaemonSession.Event) {
        switch event {
        case let .started(pid, alive):
            remotePID = pid
            if alive {
                exitMonitor = ProcessExitMonitor(pid: pid) { [weak self] in self?.childDidExit() }
            } else {
                hasExited = true
            }
        case .replayDelivered:
            settleReplayIfNeeded()
        case .exited:
            hasExited = true
        case let .failed(message):
            // e.g. the session vanished between restore and attach: show it
            // as ended (banner + "새 셸") instead of a blank, muted surface.
            failure = message
            hasExited = true
        }
    }

    /// Input stays muted until the replayed history is fully parsed, so the
    /// terminal's answers to old queries never reach the live process.
    /// Parsing only happens once a surface is attached; until then poll with
    /// backoff (a pane in a hidden barrack may wait a long time).
    private func settleReplayIfNeeded() {
        guard let remote, remote.isMutingInput, !isSettlingReplay else { return }
        isSettlingReplay = true
        Task { @MainActor [weak self] in
            var delay = AppConstants.Daemon.replaySettleInitialDelay
            while let self, let remote = self.remote, remote.isMutingInput {
                if self.probeView?.window != nil, remote.terminal.waitForPendingOutput() {
                    remote.unmuteInput()
                    break
                }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, AppConstants.Daemon.replaySettleMaxDelay)
            }
            self?.isSettlingReplay = false
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

/// Lets the daemon callback reach a pane that is still being initialized.
@MainActor
private final class PaneEventRelay {
    weak var pane: TerminalPane?
}
