import Foundation

/// A Markdown output file produced inside a barrack.
struct ArtifactFile: Identifiable, Hashable, Sendable {
    let url: URL
    let relativePath: String
    let modified: Date

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Finds recently modified `.md` artifacts. Fixed barrack knowledge
/// (RULES/SOUL/GROWTH, wiki/, sessions/, skills/) is excluded because it has
/// dedicated viewers (user decision 2026-10-31).
enum ArtifactIndex {
    static let dedicatedDirectories: Set<String> = ["wiki", "sessions", "skills"]

    static func scan(
        root: URL,
        limit: Int = AppConstants.Artifacts.listLimit
    ) -> [ArtifactFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let rootPath = root.standardizedFileURL.path
        let found: [ArtifactFile] = enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            return artifact(at: url, rootPath: rootPath, enumerator: enumerator)
        }
        return Array(found.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    private static func artifact(
        at url: URL,
        rootPath: String,
        enumerator: FileManager.DirectoryEnumerator
    ) -> ArtifactFile? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
        let relative = relativePath(of: url, rootPath: rootPath)
        if values?.isDirectory == true {
            if isExcludedDirectory(relative: relative, name: url.lastPathComponent) {
                enumerator.skipDescendants()
            }
            return nil
        }
        guard url.pathExtension.lowercased() == AppConstants.Artifacts.fileExtension else { return nil }
        guard !isDedicatedFile(relative: relative) else { return nil }
        return ArtifactFile(
            url: url,
            relativePath: relative,
            modified: values?.contentModificationDate ?? .distantPast
        )
    }

    private static func isExcludedDirectory(relative: String, name: String) -> Bool {
        if AppConstants.Artifacts.excludedDirectories.contains(name) { return true }
        let isTopLevel = !relative.contains("/")
        return isTopLevel && dedicatedDirectories.contains(name)
    }

    private static func isDedicatedFile(relative: String) -> Bool {
        let isTopLevel = !relative.contains("/")
        return isTopLevel && AppConstants.Artifacts.dedicatedViewerFiles.contains(relative)
    }

    private static func relativePath(of url: URL, rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
