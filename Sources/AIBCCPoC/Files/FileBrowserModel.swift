import Foundation
import Observation

/// What the Files screen had open in each barrack, kept while the app
/// runs: leaving for Agents and coming back shows the same folders and
/// file.
@MainActor
@Observable
final class FileBrowserModel {
    struct State: Equatable {
        var expanded: Set<URL> = []
        /// The row highlighted in the tree (a file or a folder).
        var highlighted: URL?
        /// The file shown in the reader.
        var opened: URL?
    }

    private var states: [Barrack.ID: State] = [:]

    func state(of barrack: Barrack) -> State {
        states[barrack.id] ?? State()
    }

    func toggle(_ folder: URL, in barrack: Barrack) {
        update(barrack) { state in
            if state.expanded.contains(folder) {
                // Folders inside it close too, so reopening starts tidy.
                state.expanded = state.expanded.filter { !$0.path.hasPrefix(folder.path + "/") && $0 != folder }
            } else {
                state.expanded.insert(folder)
            }
        }
    }

    func setExpanded(_ folder: URL, _ open: Bool, in barrack: Barrack) {
        guard state(of: barrack).expanded.contains(folder) != open else { return }
        toggle(folder, in: barrack)
    }

    func highlight(_ url: URL?, in barrack: Barrack) {
        update(barrack) { $0.highlighted = url }
    }

    /// Shows `file` in the reader, with its folders open in the tree.
    func open(_ file: URL, in barrack: Barrack) {
        let file = file.standardizedFileURL
        update(barrack) { state in
            state.expanded.formUnion(FileTree.ancestors(of: file, under: barrack.url))
            state.highlighted = file
            state.opened = file
        }
    }

    func close(in barrack: Barrack) {
        update(barrack) { $0.opened = nil }
    }

    private func update(_ barrack: Barrack, _ change: (inout State) -> Void) {
        var state = state(of: barrack)
        change(&state)
        states = states.merging([barrack.id: state]) { _, new in new }
    }
}
