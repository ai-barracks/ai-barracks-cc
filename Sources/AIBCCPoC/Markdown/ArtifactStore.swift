import Foundation
import Observation

/// Recent `.md` artifacts of the selected barrack plus the open document.
/// File-system changes rescan the list and reload the open document so an
/// agent rewriting a file shows up live (MD-01, MD-03).
@MainActor
@Observable
final class ArtifactStore {
    private(set) var files: [ArtifactFile] = []
    private(set) var selected: ArtifactFile?
    private(set) var content: String?
    private(set) var loadError: String?
    /// Bumped whenever `content` changes so the web view re-renders.
    private(set) var revision = 0

    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    func watch(root newRoot: URL?) {
        guard newRoot != root else { return }
        watcher?.stop()
        root = newRoot
        selected = nil
        content = nil
        files = []
        guard let newRoot else { return }
        let newWatcher = DirectoryWatcher(url: newRoot) { [weak self] in
            self?.refresh()
        }
        newWatcher.start()
        watcher = newWatcher
        refresh()
    }

    func select(_ file: ArtifactFile?) {
        selected = file
        reloadContent(force: true)
    }

    func refresh() {
        guard let root else { return }
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            let scanned = await Task.detached(priority: .utility) {
                ArtifactIndex.scan(root: root)
            }.value
            guard !Task.isCancelled else { return }
            self?.apply(scanned: scanned)
        }
    }

    private func apply(scanned: [ArtifactFile]) {
        files = scanned
        if let current = selected, let updated = scanned.first(where: { $0.url == current.url }) {
            let changed = updated.modified != current.modified
            selected = updated
            if changed { reloadContent(force: false) }
        }
    }

    private func reloadContent(force: Bool) {
        guard let file = selected else {
            content = nil
            return
        }
        do {
            let text = try String(contentsOf: file.url, encoding: .utf8)
            guard force || text != content else { return }
            content = text
            loadError = nil
            revision += 1
        } catch {
            loadError = error.localizedDescription
        }
    }
}
