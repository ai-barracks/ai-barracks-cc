import AppKit
import GhosttyTerminal
import Observation

/// What the center shows for the selected barrack (spec §4 destinations).
enum Destination: String, CaseIterable, Identifiable, Sendable {
    case sessions, rules, wiki

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessions: "세션"
        case .rules: "규칙"
        case .wiki: "Wiki"
        }
    }

    var symbol: String {
        switch self {
        case .sessions: "terminal"
        case .rules: "list.bullet.rectangle"
        case .wiki: "books.vertical"
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
    let barracks: [Barrack]
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
    @ObservationIgnored private var pendingPersist: Task<Void, Never>?
    var isArtifactPanelVisible = true
    var destination: Destination = .sessions
    var inspectorTab: InspectorTab = .artifacts
    var isNewAgentSheetPresented = false
    let maintenance = MaintenanceStore()
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
        removed.forEach { $0.terminate() }
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
        guard let known = daemon.listSessions().map({ Set($0.map(\.id)) }) else {
            restoreSummary = "daemon session list unavailable"
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

    private func persist() {
        pendingPersist?.cancel()
        pendingPersist = nil
        guard let daemon else { return }
        let saved = SavedWorkspace(selectedBarrackID: selectedBarrackID, grids: grids.mapValues { grid in
            SavedWorkspace.Grid(
                layout: grid.layout.rawValue, splitX: Double(grid.splitX), splitY: Double(grid.splitY),
                panes: grid.panes.compactMap { pane in
                    pane.remote.map { SavedWorkspace.Pane(session: $0.id, title: pane.title) }
                }
            )
        })
        SessionStore.save(saved, to: daemon.sessionStoreURL)
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
        openPane(title: client.label, command: AgentLauncher.command(for: client, skipPermissions: skipPermissions))
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
