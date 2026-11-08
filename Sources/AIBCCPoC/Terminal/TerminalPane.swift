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
    /// Started as a plain login shell (no command, not a reattach).
    let isPlainShell: Bool
    /// Where it started, and the command as the user gave it (not the
    /// shell wrapper): what "Quick Command로 저장" fills in (v1 Save). A
    /// reattached pane whose launch was not recorded has no folder.
    let workingDirectory: String?
    let userCommand: String?
    /// Started as this agent: nothing is typed into it on the user's behalf.
    /// Settable so a self-test can turn a fixture into an agent mid-flow.
    var agent: AgentClient?
    let state: TerminalViewState
    /// Daemon link (daemon backend only).
    let remote: DaemonSession?
    /// The child exited; the pane keeps its final output on screen.
    private(set) var hasExited = false
    private(set) var failure: String?
    /// A passing warning that does not end the pane (input refused).
    private(set) var notice: String?
    /// The child had already ended when this pane attached to it.
    private(set) var endedBeforeAttach = false
    /// The exit was confirmed (daemon EXITED, or the exec child gone), not
    /// only the connection lost: the archive saved now is final.
    private(set) var exitConfirmed = false
    @ObservationIgnored private var ownedView: ProbeTerminalView?
    @ObservationIgnored private var exitMonitor: ProcessExitMonitor?
    @ObservationIgnored private var remotePID: pid_t?
    @ObservationIgnored private var reportedExit = false
    @ObservationIgnored private var noticeGeneration = 0
    /// Called once the child is gone and its output is on screen (the
    /// workspace archives it).
    @ObservationIgnored var onExit: (@MainActor (TerminalPane) -> Void)?

    var probeView: ProbeTerminalView? { ownedView }
    var monitoredPID: pid_t? { exitMonitor?.pid ?? remotePID }
    var isChildGone: Bool { exitMonitor?.isGone ?? false }
    /// The archive key: the daemon session outlives the pane (a relaunch
    /// attaches a new pane to it), so its output is kept under the session.
    var archiveID: String { (remote?.id ?? id).uuidString }
    /// A daemon-owned plain shell with nothing running under it: the place a
    /// new agent may take when the grid is full. Exec panes are never judged
    /// (their visible pid is the foreground program, not the shell).
    var isIdleShell: Bool {
        guard isPlainShell, remote != nil, !hasExited, let pid = remotePID, pid > 0 else { return false }
        return !ProcessTree.hasChildren(pid)
    }

    /// Root process of the pane: the daemon's child, or Ghostty's.
    var processID: pid_t? { remote == nil ? probeView?.foregroundPid : remotePID }

    init(
        controller: TerminalController,
        title: String,
        workingDirectory: String?,
        command: String? = nil,
        extraEnvironment: [String: String] = [:],
        backend: PaneBackend = .exec,
        userCommand: String? = nil,
        agent: AgentClient? = nil
    ) {
        let paneID = UUID()
        let environment = Self.environment(paneID: paneID, extra: extraEnvironment)
        let viewState = TerminalViewState(controller: controller)
        let relay = PaneEventRelay()
        var attaching = false
        switch backend {
        case .exec:
            remote = nil
            viewState.configuration = TerminalSurfaceOptions(
                backend: .exec, workingDirectory: workingDirectory, envVars: environment, command: command
            )
        case let .daemon(daemon, sessionID, attach):
            attaching = attach
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
        isPlainShell = command == nil && !attaching
        self.workingDirectory = workingDirectory
        self.userCommand = userCommand
        self.agent = agent
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
    /// (exec only: a daemon pane learns its child from `.started`).
    func startExitMonitorIfNeeded() {
        guard remote == nil, exitMonitor == nil, !hasExited, let pid = probeView?.foregroundPid, pid > 0 else { return }
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
        // A daemon pane's last output may still be on the socket: it is
        // archived on `.outputComplete` instead.
        if remote == nil {
            exitConfirmed = true
            reportExit()
        }
    }

    private func reportExit() {
        guard !reportedExit else { return }
        reportedExit = true
        onExit?(self)
    }

    private func handle(_ event: DaemonSession.Event) {
        switch event {
        case let .started(pid, alive):
            remotePID = pid
            if alive {
                exitMonitor = ProcessExitMonitor(pid: pid) { [weak self] in self?.childDidExit() }
            } else {
                // Ended while no pane was attached: archived on
                // `.outputComplete` unless a final archive of it exists.
                hasExited = true
                endedBeforeAttach = true
            }
        case .exited:
            hasExited = true
        case let .outputComplete(final):
            exitConfirmed = final
            reportExit()
        case let .failed(message):
            // e.g. the session vanished between restore and attach: show it
            // as ended (banner + "새 셸") instead of a blank surface.
            failure = message
            hasExited = true
        case .inputRefused:
            // Codex r6: this used to end the pane while the program ran on.
            showNotice("입력을 보내지 못함 — 프로그램이 입력을 읽지 않고 있습니다")
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeGeneration += 1
        let generation = noticeGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: AppConstants.Daemon.noticeDuration)
            if self?.noticeGeneration == generation { self?.notice = nil }
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
