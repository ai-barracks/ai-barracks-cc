import Foundation

/// Leaving an open edit asks first, whichever way the user navigates
/// (sidebar, barrack list, ⌘K, notices) — r5: only the document list asked.
/// The model's own entry points that move the user (⌘⇧A, the pane menu,
/// search hits, notices, new panes) guard themselves, so no caller can skip
/// the question (r6).
extension WorkspaceModel {
    func navigate(_ action: @escaping @MainActor () -> Void) {
        guard editInProgress else { return action() }
        pendingNavigation = action
        isConfirmingNavigation = true
    }

    /// The user chose to discard the edit.
    func confirmNavigation() {
        let action = pendingNavigation
        pendingNavigation = nil
        isConfirmingNavigation = false
        editInProgress = false
        // The editor drops its buffer even where the action leaves it on
        // screen; clearing the flag alone left a dirty editor unguarded (r6).
        discardRevision += 1
        action?()
    }

    /// Shows the terminal grid, focusing `pane` — after asking, if an edit
    /// is open. The pane itself is already in the grid.
    func showSessions(focusing pane: TerminalPane?) {
        navigate { [weak self] in
            self?.destination = .sessions
            if let pane { self?.focusWhenAttached(pane) }
        }
    }

    func cancelNavigation() {
        pendingNavigation = nil
        isConfirmingNavigation = false
    }
}
