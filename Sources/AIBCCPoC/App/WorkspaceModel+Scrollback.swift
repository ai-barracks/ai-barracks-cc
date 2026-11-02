import Foundation

/// Terminal output archive (v1 C7): a pane's screen text is kept when the
/// pane leaves the grid or its program ends.
extension WorkspaceModel {
    func archive(_ pane: TerminalPane, barrackPath: String?) {
        guard let text = pane.probeView?.readScreenText(),
              scrollback.save(id: pane.id.uuidString, title: pane.title, barrackPath: barrackPath, text: text) != nil else { return }
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
