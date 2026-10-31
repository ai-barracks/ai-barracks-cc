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

    /// Directory currently watched (read-only, for tests and diagnostics).
    var watchedRoot: URL? { root }

    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// Incremented on every root change; stale scans compare and drop out.
    @ObservationIgnored private var generation = 0

    func watch(root newRoot: URL?) {
        guard newRoot != root else { return }
        scanTask?.cancel()
        generation += 1
        watcher?.stop()
        watcher = nil
        root = newRoot
        clearSelection()
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
        guard let file else {
            clearSelection()
            return
        }
        selected = file
        reloadContent(force: true)
    }

    func refresh() {
        guard let root else { return }
        scanTask?.cancel()
        let scanGeneration = generation
        scanTask = Task { [weak self] in
            let scanned = await Task.detached(priority: .utility) {
                ArtifactIndex.scan(root: root)
            }.value
            guard !Task.isCancelled, let self, self.generation == scanGeneration, self.root == root else { return }
            self.apply(scanned: scanned)
        }
    }

    private func apply(scanned: [ArtifactFile]) {
        files = scanned
        guard let current = selected else { return }
        if let updated = scanned.first(where: { $0.url == current.url }) {
            let changed = updated.modified != current.modified
            selected = updated
            if changed { reloadContent(force: false) }
        } else if FileManager.default.fileExists(atPath: current.url.path) {
            // Fell out of the top-N list but still exists: keep it fresh.
            reloadContent(force: false)
        } else {
            clearSelection()
        }
    }

    private func reloadContent(force: Bool) {
        guard let file = selected else { return }
        do {
            let text = try String(contentsOf: file.url, encoding: .utf8)
            loadError = nil
            guard force || text != content else { return }
            content = text
            revision += 1
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func clearSelection() {
        selected = nil
        content = nil
        loadError = nil
    }
}
