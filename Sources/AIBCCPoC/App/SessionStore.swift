import Foundation

/// Which daemon sessions each barrack's grid shows, so a relaunched app
/// reattaches to the same shells in the same layout (daemon backend only).
struct SavedWorkspace: Codable, Sendable {
    struct Pane: Codable, Sendable {
        let session: UUID
        let title: String
        /// How it was started (absent in records written before them).
        var command: String?
        var directory: String?
        var agent: String?
    }

    struct Grid: Codable, Sendable {
        let layout: Int
        let splitX: Double
        let splitY: Double
        let panes: [Pane]
    }

    let selectedBarrackID: String?
    let grids: [String: Grid]
}

extension SavedWorkspace {
    /// `current` plus every pane of `kept` it does not already name (a grid
    /// gets them after its own panes; a barrack it lacks gets kept's grid).
    static func keeping(_ kept: SavedWorkspace, in current: SavedWorkspace) -> SavedWorkspace {
        var grids = current.grids
        for (barrack, old) in kept.grids {
            guard let now = grids[barrack] else {
                grids[barrack] = old
                continue
            }
            let named = Set(now.panes.map(\.session))
            grids[barrack] = Grid(layout: now.layout, splitX: now.splitX, splitY: now.splitY,
                                  panes: now.panes + old.panes.filter { !named.contains($0.session) })
        }
        return SavedWorkspace(selectedBarrackID: current.selectedBarrackID, grids: grids)
    }
}

enum SessionStore {
    static func load(from url: URL) -> SavedWorkspace? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedWorkspace.self, from: data)
    }

    /// Atomic replace, owner-only: the file names live shell sessions.
    @discardableResult
    static func save(_ workspace: SavedWorkspace, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(workspace) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}
