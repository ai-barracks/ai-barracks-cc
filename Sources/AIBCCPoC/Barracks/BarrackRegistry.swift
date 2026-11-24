import Foundation

/// A barrack registered with the aib CLI (`~/.aib/barracks.json`).
struct Barrack: Identifiable, Hashable, Decodable, Sendable {
    let name: String
    let path: String
    let description: String?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// Read-only access to the aib registry. The PoC never writes it.
enum BarrackRegistry {
    static func load(from registryPath: String = AppConstants.Paths.barracksRegistry) -> [Barrack] {
        read(from: registryPath) ?? []
    }

    /// nil when the file is missing, empty (0 bytes) or not a list — an aib
    /// write in progress or a damaged file, not "no barracks" (the old
    /// barracks.json loss). A real `[]` (the last barrack removed) is [] (r5).
    static func read(from registryPath: String = AppConstants.Paths.barracksRegistry) -> [Barrack]? {
        let expanded = (registryPath as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded), !data.isEmpty,
              let decoded = try? JSONDecoder().decode([Barrack].self, from: data) else { return nil }
        return decoded.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
