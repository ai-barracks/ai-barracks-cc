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
        let expanded = (registryPath as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded) else { return [] }
        guard let decoded = try? JSONDecoder().decode([Barrack].self, from: data) else { return [] }
        return decoded.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
