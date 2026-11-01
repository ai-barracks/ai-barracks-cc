import Foundation

/// Which daemon sessions each barrack's grid shows, so a relaunched app
/// reattaches to the same shells in the same layout (daemon backend only).
struct SavedWorkspace: Codable, Sendable {
    struct Pane: Codable, Sendable {
        let session: UUID
        let title: String
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
