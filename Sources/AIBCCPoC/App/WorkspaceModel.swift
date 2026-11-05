import AppKit
import GhosttyTerminal
import Observation

/// What the center shows for the selected barrack (spec §4 destinations).
enum Destination: String, CaseIterable, Identifiable, Sendable {
    case sessions, history, rules, wiki, skills, council, git

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessions: "세션"
        case .history: "기록"
        case .rules: "규칙"
        case .wiki: "Wiki"
        case .skills: "Skills"
        case .council: "Council"
        case .git: "Git"
        }
    }

    var symbol: String {
        switch self {
        case .sessions: "terminal"
        case .history: "clock.arrow.circlepath"
        case .rules: "list.bullet.rectangle"
        case .wiki: "books.vertical"
        case .skills: "puzzlepiece.extension"
        case .council: "person.3"
        case .git: "arrow.triangle.branch"
        }
    }
}

/// Right inspector tabs (spec §4): artifacts first (P1).
enum InspectorTab: String, CaseIterable, Identifiable, Sendable {
    case artifacts, context, maintenance

    var id: String { rawValue }
    var label: String {
        switch self {
        case .artifacts: "산출물"
        case .context: "문맥"
        case .maintenance: "정비"
        }
    }
}

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
/// views, and Ghostty keeps a surface across detach/reattach. With the
/// daemon backend the grids are also saved, and a relaunch reattaches to the
/// same shells.
@MainActor
@Observable
final class WorkspaceModel {
    let controller: TerminalController
    private(set) var barracks: [Barrack]
    /// nil = Ghostty's exec backend (shells end with the app).
    let daemon: DaemonBackend?

    var selectedBarrackID: Barrack.ID? {
        willSet { terminalHadFocus = isTerminalFocused() }
        didSet {
            activateSelectedGrid()
            persist()
            // Hand keyboard focus over only if a terminal had it; keyboard
            // navigation in the sidebar keeps its focus (Codex review r3 #5).
            if terminalHadFocus { focusFirstVisiblePaneWhenAttached() }
        }
    }
    @ObservationIgnored private var terminalHadFocus = false
    /// What the launch-time reattach did (self-test environment evidence).
    @ObservationIgnored private(set) var restoreSummary = "not attempted"
    /// The saved layout whose sessions could not be confirmed (the daemon's
    /// list failed): every save keeps referring to them, so the next launch
    /// reattaches instead of killing them as orphans (Codex r4).
    @ObservationIgnored private var unconfirmed: SavedWorkspace?
    @ObservationIgnored private var pendingPersist: Task<Void, Never>?
    var isArtifactPanelVisible = true
    var destination: Destination = .sessions
    var inspectorTab: InspectorTab = .artifacts
    var isNewAgentSheetPresented = false
    var isCouncilSheetPresented = false
    var isAddBarrackPresented = false
    /// 기록 destination shows the terminal output archive tab.
    var historyShowsArchive = false
    /// An open document edit (DocumentView): navigation asks first (r5).
    var editInProgress = false
    /// Navigation waiting for "discard the edit?" (alert shown while true).
    var isConfirmingNavigation = false
    @ObservationIgnored var pendingNavigation: (@MainActor () -> Void)?
    /// Asked to unregister (confirmation dialog shown while set).
    var barrackToRemove: Barrack?
    var isPalettePresented = false
    /// Set by ⌘K results; the destination view selects it and clears it.
    var pendingDocument: URL?
    var pendingSessionID: String?
    /// Opens the selected document's form editor (gallery; later ⌘K).
    var pendingStructuredEdit = false
    let maintenance = MaintenanceStore()
    let notices = NoticeCenter()
    let quickCommands = QuickCommandStore()
    let scrollback = ScrollbackArchive.standard
    @ObservationIgnored var lastScrollbackCollection: Date?
    /// Bumped when the output archive changes (the archive view reloads).
    var archiveRevision = 0
    /// Non-nil while the Quick Command sheet is open.
    var quickCommandDraft: QuickCommand?
    @ObservationIgnored private(set) var health: HealthMonitor?
    /// Scheduled activation (not in self-tests).
    @ObservationIgnored private(set) var activation: ActivationScheduler?
    @ObservationIgnored private var registryWatcher: DirectoryWatcher?
    let liveness: LivenessStore
    private(set) var grids: [String: BarrackGrid] = [:]

    init(barracks: [Barrack] = BarrackRegistry.load(), daemon: DaemonBackend? = DaemonBackend.fromArguments()) {
        controller = TerminalAppearance.makeController()
        self.barracks = barracks
        self.daemon = daemon
        liveness = LivenessStore(barracks: barracks)
        // Restore first: with @Observable the didSet below already runs in
        // init, and it would save a fresh grid over the saved layout.
        let restoredSelection = daemon.flatMap { restore(from: $0) }
        selectedBarrackID = restoredSelection ?? barracks.first?.id
        activateSelectedGrid()
        startBackgroundWork()
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
                          splitY: y.map(clamp) ?? current.splitY),
              persisting: .debounced)
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
        makePane(title: title, command: command, environment: environment,
                 directory: selectedBarrack?.path, attachingTo: nil)
    }

    private func makePane(
        title: String,
        command: String?,
        environment: [String: String],
        directory: String?,
        attachingTo session: UUID?
    ) -> TerminalPane {
        let backend: PaneBackend = daemon.map {
            .daemon($0, sessionID: session ?? UUID(), attach: session != nil)
        } ?? .exec
        let pane = TerminalPane(
            controller: controller,
            title: title,
            workingDirectory: directory,
            command: command,
            extraEnvironment: environment,
            backend: backend
        )
        let paneID = pane.id
        pane.onExit = { [weak self] pane in self?.archive(pane, barrackPath: directory) }
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

    private enum Persisting { case now, debounced }

    private func store(_ newGrid: BarrackGrid, persisting: Persisting = .now) {
        let kept = Set(newGrid.panes.map(\.id))
        let removed = (grids[gridKey]?.panes ?? []).filter { !kept.contains($0.id) }
        grids = grids.merging([gridKey: newGrid]) { _, new in new }
        removed.forEach { pane in
            archive(pane, barrackPath: selectedBarrack?.path)
            pane.terminate()
        }
        updateSurfaceVisibility()
        switch persisting {
        case .now: persist()
        case .debounced: persistSoon()
        }
    }

    private func persistSoon() {
        guard daemon != nil else { return }
        pendingPersist?.cancel()
        pendingPersist = Task { @MainActor [weak self] in
            try? await Task.sleep(for: AppConstants.Daemon.persistDebounce)
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    // MARK: - Daemon session persistence

    /// Reattaches every saved pane whose session the daemon still holds;
    /// a grid that lost sessions is topped up with fresh shells. Returns the
    /// saved selection. Must not touch `selectedBarrackID` (its didSet saves).
    private func restore(from daemon: DaemonBackend) -> Barrack.ID? {
        guard let saved = SessionStore.load(from: daemon.sessionStoreURL) else {
            restoreSummary = "no saved layout"
            return nil
        }
        guard let known = Self.listWithRetry(daemon) else {
            unconfirmed = saved
            restoreSummary = "daemon session list unavailable; saved sessions kept"
            return nil
        }
        // Sessions no saved pane refers to were orphaned (e.g. a kill lost
        // in a crash); nothing can ever attach to them again.
        let referenced = Set(saved.grids.values.flatMap(\.panes).map(\.session))
        let orphans = known.subtracting(referenced)
        daemon.killSessions(Array(orphans))
        let restored: [String: BarrackGrid] = barracks.reduce(into: [:]) { result, barrack in
            guard let grid = saved.grids[barrack.id] else { return }
            let attached = grid.panes.filter { known.contains($0.session) }.map {
                makePane(title: $0.title, command: nil, environment: [:], directory: barrack.path, attachingTo: $0.session)
            }
            guard !attached.isEmpty else { return }
            let layout = PaneLayout(rawValue: grid.layout) ?? .single
            let fresh = (attached.count..<max(layout.paneCount, attached.count)).map {
                makePane(title: "shell \($0 + 1)", command: nil, environment: [:], directory: barrack.path, attachingTo: nil)
            }
            result[barrack.id] = BarrackGrid(panes: attached + fresh, layout: layout,
                                             splitX: CGFloat(grid.splitX), splitY: CGFloat(grid.splitY))
        }
        grids = restored
        let savedPanes = saved.grids.values.map(\.panes.count).reduce(0, +)
        let attachedPanes = restored.values.flatMap(\.panes).filter { $0.remote.map { known.contains($0.id) } ?? false }
        restoreSummary = "saved=\(savedPanes) attached=\(attachedPanes.count) grids=\(restored.count) "
            + "orphans_killed=\(orphans.count)"
        return saved.selectedBarrackID.flatMap { selected in barracks.first { $0.id == selected }?.id }
    }

    private static func listWithRetry(_ daemon: DaemonBackend, attempts: Int = 3) -> Set<UUID>? {
        for attempt in 0..<attempts {
            if let sessions = daemon.listSessions() { return Set(sessions.map(\.id)) }
            if attempt < attempts - 1 { usleep(200_000) }
        }
        return nil
    }

    private func persist() {
        pendingPersist?.cancel()
        pendingPersist = nil
        guard let daemon else { return }
        let current = SavedWorkspace(selectedBarrackID: selectedBarrackID, grids: grids.mapValues { grid in
            SavedWorkspace.Grid(
                layout: grid.layout.rawValue, splitX: Double(grid.splitX), splitY: Double(grid.splitY),
                panes: grid.panes.compactMap { pane in
                    pane.remote.map { SavedWorkspace.Pane(session: $0.id, title: pane.title) }
                }
            )
        })
        SessionStore.save(unconfirmed.map { SavedWorkspace.keeping($0, in: current) } ?? current, to: daemon.sessionStoreURL)
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

    private func isTerminalFocused() -> Bool {
        grid.panes.contains { pane in
            guard let view = pane.probeView, let responder = view.window?.firstResponder as? NSView else { return false }
            return responder === view || responder.isDescendant(of: view)
        }
    }

    private func focusFirstVisiblePaneWhenAttached() {
        let target = grid.panes.first
        Task { @MainActor in
            for _ in 0..<AppConstants.Layout.focusHandoffAttempts {
                if let view = target?.probeView, let window = view.window {
                    window.makeFirstResponder(view)
                    return
                }
                try? await Task.sleep(for: AppConstants.SelfTest.pollInterval)
            }
        }
    }

    private func makeShellPanes(count: Int, startingAt offset: Int) -> [TerminalPane] {
        (0..<max(count, 0)).map { index in
            makePane(title: "shell \(offset + index + 1)")
        }
    }
}

// MARK: - Agents and attention (spec §7: ⌘N, ⌘⇧A)

extension WorkspaceModel {
    /// ⌘N: a new pane running `aib start <client>` in the selected barrack.
    /// The preset grows to make room (1 → 2 → 4); nil when four are full.
    @discardableResult
    func launchAgent(_ client: AgentClient, skipPermissions: Bool) -> TerminalPane? {
        openPane(title: client.label, command: AgentLauncher.command(for: client, skipPermissions: skipPermissions,
                                                                     profile: ProviderProfiles.load(client)))
    }

    /// 정비 actions run where the user sees them: a new pane in the
    /// barrack, through a login shell that stays afterwards.
    @discardableResult
    func runInPane(title: String, command: String) -> TerminalPane? {
        openPane(title: title, command: "/bin/zsh -lc " + AgentLauncher.shellQuote(command + "; exec /bin/zsh -l"))
    }

    private func openPane(title: String, command: String?) -> TerminalPane? {
        guard let barrack = selectedBarrack else { return nil }
        let current = grid
        guard current.panes.count < PaneLayout.quad.paneCount else { return nil }
        let pane = makePane(title: title, command: command, environment: [:], directory: barrack.path, attachingTo: nil)
        let panes = current.panes + [pane]
        let needed = max(panes.count, current.layout.paneCount)
        let layout = PaneLayout.allCases.first { $0.paneCount >= needed } ?? .quad
        store(BarrackGrid(panes: panes, layout: layout, splitX: current.splitX, splitY: current.splitY))
        destination = .sessions
        focusWhenAttached(pane)
        return pane
    }

    /// ⌘⇧A: the next session that needs the user (blocked first), in the
    /// fixed barrack order. Selects its barrack and focuses the pane that
    /// runs it; a `done` is acknowledged on arrival (never a `blocked`).
    @discardableResult
    func goToNextAttention() -> LiveSession? {
        let candidates = barracks.flatMap { barrack in
            liveness.sessions(of: barrack.id).filter(\.needsAttention).map { (barrack, $0) }
        }
        guard let (barrack, session) = candidates.first(where: { $0.1.state == .blocked }) ?? candidates.first else {
            return nil
        }
        selectedBarrackID = barrack.id
        destination = .sessions
        if let pane = pane(running: session, in: barrack.id) {
            focusWhenAttached(pane)
        } else {
            isArtifactPanelVisible = true
            inspectorTab = .context
        }
        if session.state == .done {
            LivenessAck.write(barrackPath: barrack.path, sessionID: session.id, runID: session.runID)
            liveness.refresh()
        }
        return session
    }

    /// The pane whose process tree contains the session's agent pid.
    func pane(running session: LiveSession, in barrackID: Barrack.ID) -> TerminalPane? {
        guard session.pid > 0 else { return nil }
        return grids[barrackID]?.panes.first { pane in
            pane.processID.map { ProcessTree.isDescendant(session.pid, of: $0) } ?? false
        }
    }

    func focusWhenAttached(_ pane: TerminalPane) {
        Task { @MainActor in
            for _ in 0..<AppConstants.Layout.focusHandoffAttempts {
                if let view = pane.probeView, let window = view.window {
                    window.makeFirstResponder(view)
                    return
                }
                try? await Task.sleep(for: AppConstants.SelfTest.pollInterval)
            }
        }
    }
}

// MARK: - Daemon sessions

extension WorkspaceModel {
    /// Ends every shell and agent the daemon holds, after confirmation.
    func confirmEndAllSessions() {
        guard let daemon else { return }
        let alert = NSAlert()
        alert.messageText = "모든 세션을 종료할까요?"
        alert.informativeText = "모든 배럭의 터미널과 에이전트가 종료됩니다. 실행 중인 작업은 중단됩니다."
        alert.addButton(withTitle: "모두 종료")
        alert.addButton(withTitle: "취소")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        daemon.shutdownSessions()
    }
}

// MARK: - ⌘K results

extension WorkspaceModel {
    /// Opens a search hit where it lives: its barrack, then the session
    /// record, the Wiki topic or the rules document.
    func open(_ hit: SearchHit) {
        selectedBarrackID = hit.barrackID
        switch hit.source {
        case .session:
            pendingSessionID = hit.title
            destination = .history
        case .wiki:
            pendingDocument = hit.file
            destination = .wiki
        case .rules, .config:
            pendingDocument = hit.file
            destination = .rules
        }
    }
}

// MARK: - Health, notices, registry (v1 watcher parity)

extension WorkspaceModel {
    /// Self-tests run without background checks or toasts over the window.
    private var isSelfTest: Bool { CommandLine.arguments.contains { $0.hasPrefix("--selftest") } }

    fileprivate func startBackgroundWork() {
        liveness.onNewAttention = { [weak self] sessions in self?.announce(sessions) }
        guard !isSelfTest else { return }
        let monitor = HealthMonitor(workspace: self, notices: notices)
        health = monitor
        monitor.start()
        // Shares v1's file and lock: only one app schedules.
        let scheduler = ActivationScheduler(directory: AppConstants.Activation.directory)
        activation = scheduler
        scheduler.start()
        let registry = URL(fileURLWithPath: (AppConstants.Paths.barracksRegistry as NSString).expandingTildeInPath)
        let watcher = DirectoryWatcher(url: registry.deletingLastPathComponent()) { [weak self] in self?.reloadRegistry() }
        watcher.start()
        registryWatcher = watcher
    }

    /// ~/.aib/barracks.json changed (aib init / barracks remove): new list,
    /// same grids for barracks that remain.
    func reloadRegistry(_ read: [Barrack]? = BarrackRegistry.read()) {
        guard let loaded = read, loaded != barracks else { return }
        barracks = loaded
        liveness.update(barracks: loaded)
        if let selected = selectedBarrackID, !loaded.contains(where: { $0.id == selected }) {
            selectedBarrackID = loaded.first?.id
        }
    }

    private func announce(_ sessions: [LiveSession]) {
        for session in sessions {
            let barrackID = liveness.barrackID(of: session)
            let name = barracks.first { $0.id == barrackID }?.name ?? ""
            notices.post(AppNotice(kind: .attention, title: "\(name): \(session.state.label)",
                                   body: session.id, actionLabel: "이동", barrackID: barrackID, sessionID: session.id))
        }
    }

    /// A toast's action.
    func perform(_ notice: AppNotice) {
        notices.dismiss(notice.id)
        switch notice.kind {
        case .stale:
            if let barrack = notice.barrackID { selectedBarrackID = barrack }
            pendingSessionID = notice.sessionID
            destination = .history
        case .sync:
            syncAll(paths: health?.outdatedBarracks ?? [])
        case .registry:
            break
        case .export:
            if let path = notice.sessionID { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        case .attention:
            if let barrack = notice.barrackID { selectedBarrackID = barrack }
            destination = .sessions
            if let id = notice.sessionID, let barrack = notice.barrackID,
               let session = liveness.sessions(of: barrack).first(where: { $0.id == id }),
               let pane = pane(running: session, in: barrack) {
                focusWhenAttached(pane)
            }
        }
    }

    /// v1 "Sync All Barracks": every given barrack (all if none), dry run
    /// first, applied on Enter, in a pane.
    @discardableResult
    func syncAll(paths: [String]) -> TerminalPane? {
        let targets = (paths.isEmpty ? barracks.map(\.path) : paths).map(AgentLauncher.shellQuote).joined(separator: " ")
        return runInPane(title: "Sync All", command: SyncAll.command(quotedPaths: targets))
    }
}

enum SyncAll {
    static func command(quotedPaths: String) -> String {
        MaintenanceScanner.confirmThenApply("for p in \(quotedPaths); do aib sync --dry-run \"$p\"; done",
                                            "for p in \(quotedPaths); do aib sync \"$p\"; done")
    }
}

// MARK: - Terminal management (v1 terminal tab bar parity)

extension WorkspaceModel {
    /// The pane with keyboard focus, else the first visible one.
    var focusedPane: TerminalPane? {
        let visible = panes.prefix(layout.paneCount)
        return visible.first { pane in
            guard let view = pane.probeView, let responder = view.window?.firstResponder as? NSView else { return false }
            return responder === view || responder.isDescendant(of: view)
        } ?? visible.first
    }

    /// Ends the pane's shell; the preset shrinks to fit what is left, and
    /// a barrack never ends up without a terminal.
    func closePane(id paneID: UUID) {
        let current = grid
        let remaining = current.panes.filter { $0.id != paneID }
        let panes = remaining.isEmpty ? [makePane(title: "shell 1")] : remaining
        let fitting = PaneLayout.allCases.first { $0.paneCount >= min(panes.count, current.layout.paneCount) } ?? .single
        store(BarrackGrid(panes: panes, layout: fitting, splitX: current.splitX, splitY: current.splitY))
    }

    /// Moves a (possibly hidden) pane into the first slot and focuses it.
    func bringToFront(id paneID: UUID) {
        let current = grid
        guard let pane = current.panes.first(where: { $0.id == paneID }) else { return }
        store(BarrackGrid(panes: [pane] + current.panes.filter { $0.id != paneID }, layout: current.layout,
                          splitX: current.splitX, splitY: current.splitY))
        destination = .sessions
        focusWhenAttached(pane)
    }

    /// Types the command into the pane and presses Enter.
    @discardableResult
    func run(_ quick: QuickCommand, in pane: TerminalPane? = nil) -> Bool {
        guard let target = pane ?? focusedPane else { return false }
        destination = .sessions
        focusWhenAttached(target)
        return target.state.performBindingAction(GhosttyText.action(typing: quick.command, pressEnter: true))
    }

    func exportOutput(of pane: TerminalPane) {
        guard let barrack = selectedBarrack else { return }
        let text = pane.probeView?.readScreenText() ?? ""
        switch TerminalExport.write(text, barrackPath: barrack.path, title: pane.title) {
        case let .success(url):
            notices.post(AppNotice(kind: .export, title: "출력 내보냄", body: url.path, actionLabel: "Finder에서 보기",
                                   barrackID: nil, sessionID: url.path))
        case let .failure(failure):
            notices.post(AppNotice(kind: .export, title: "내보내지 못함",
                                   body: failure == .empty ? "내보낼 출력이 없습니다" : "sessions 폴더에 쓸 수 없습니다",
                                   actionLabel: nil, barrackID: nil, sessionID: nil))
        }
    }
}

// MARK: - Settings

extension WorkspaceModel {
    /// Re-applies terminal settings to every open surface.
    func applySettings(_ settings: AppSettings.Terminal = AppSettings.terminal()) {
        controller.setTerminalConfiguration(TerminalAppearance.configuration(settings))
    }
}

