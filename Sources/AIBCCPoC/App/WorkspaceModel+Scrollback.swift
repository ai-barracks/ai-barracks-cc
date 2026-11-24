import Foundation

/// Terminal output archive (v1 C7): a pane's screen text is kept when the
/// pane leaves the grid or its program ends.
extension WorkspaceModel {
    func archive(_ pane: TerminalPane, barrackPath: String?) {
        // A session that ended while no pane was attached is archived once,
        // on the first attach that parses its last output — unless only a
        // snapshot of it was kept so far (r7: a lost connection archived the
        // middle, and the real end was then skipped).
        if pane.endedBeforeAttach, scrollback.record(pane.archiveID)?.final == true { return }
        guard let text = pane.probeView?.readScreenText(),
              scrollback.save(id: pane.archiveID, title: pane.title, barrackPath: barrackPath, text: text,
                              final: pane.exitConfirmed) != nil else { return }
        let now = Date()
        if lastScrollbackCollection.map({ now.timeIntervalSince($0) > AppConstants.Scrollback.gcInterval }) ?? true {
            lastScrollbackCollection = now
            scrollback.collectGarbage(now: now)
        }
        archiveRevision += 1
    }

    func deleteArchived(_ id: String) {
        scrollback.delete(id)
        archiveRevision += 1
    }

    func deleteAllArchived() {
        scrollback.deleteAll()
        archiveRevision += 1
    }
}
