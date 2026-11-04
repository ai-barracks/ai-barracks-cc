import Foundation

/// Leaving an open edit asks first, whichever way the user navigates
/// (sidebar, barrack list, ⌘K, notices) — r5: only the document list asked.
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
        action?()
    }

    func cancelNavigation() {
        pendingNavigation = nil
        isConfirmingNavigation = false
    }
}
