import Foundation

/// What each shortcut does (menus call the same).
extension WorkspaceModel {
    func perform(_ action: ShortcutAction) {
        if let destination = action.destination {
            return navigate { [weak self] in self?.destination = destination }
        }
        if let layout = action.layout { return setLayout(layout) }
        switch action {
        case .palette: isPalettePresented = true
        case .newAgent: isNewAgentSheetPresented = true
        case .newTerminal: _ = launchAgent(.terminal, skipPermissions: false)
        case .wrapUp: toggleWrapUp(of: wrapUpTarget)
        case .closeTerminal: requestClose(wrapUpTarget)
        case .nextAttention: _ = goToNextAttention()
        case .acknowledgeFinished: acknowledgeFinished()
        case .council: isCouncilSheetPresented = true
        case .focusNextPane: focusAdjacentPane(1)
        case .focusPreviousPane: focusAdjacentPane(-1)
        case .toggleOutputs: isArtifactPanelVisible.toggle()
        case .toggleAgentList:
            let key = AppConstants.Terminal.agentListShownKey
            UserDefaults.standard.set(!(UserDefaults.standard.object(forKey: key) as? Bool ?? true), forKey: key)
        case .nextBarrack: selectAdjacentBarrack(1)
        case .previousBarrack: selectAdjacentBarrack(-1)
        default: break
        }
    }

    /// Asks before closing a running terminal; an ended one just goes.
    func requestClose(_ pane: TerminalPane?) {
        guard let pane else { return }
        if pane.hasExited { closePane(id: pane.id) } else { closeRequest = pane }
    }

    /// Keyboard focus to the next (or previous) slot on screen, round.
    func focusAdjacentPane(_ step: Int) {
        let visible = Array(panes.prefix(layout.paneCount))
        guard !visible.isEmpty else { return }
        let current = focusedSlot ?? (step > 0 ? -1 : 0)
        let next = ((current + step) % visible.count + visible.count) % visible.count
        let pane = visible[next]
        navigate { [weak self] in
            self?.destination = .sessions
            self?.focusWhenAttached(pane)
        }
    }

    /// The next (or previous) barrack in the sidebar's order, round.
    func selectAdjacentBarrack(_ step: Int) {
        guard !barracks.isEmpty else { return }
        let current = barracks.firstIndex { $0.id == selectedBarrackID } ?? (step > 0 ? -1 : 0)
        let next = barracks[((current + step) % barracks.count + barracks.count) % barracks.count].id
        guard next != selectedBarrackID else { return }
        navigate { [weak self] in self?.selectedBarrackID = next }
    }
}
