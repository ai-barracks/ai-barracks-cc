import Foundation

/// One entry of a barrack's folder as the Files screen lists it.
struct FileNode: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool
    var modified: Date?
    var created: Date?

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// How the tree orders a folder's entries (2026-11-16 request: by name and
/// by date, created and modified). Folders stay ahead of files; under a
/// date order entries without that date come last, and ties go by name.
struct FileOrder: Equatable, Sendable {
    enum Key: String, CaseIterable, Identifiable, Sendable {
        case name, modified, created

        var id: String { rawValue }

        var label: String {
            switch self {
            case .name: "이름"
            case .modified: "수정한 날짜"
            case .created: "만든 날짜"
            }
        }
    }

    var key: Key = .name
    var ascending = true

    static let byName = FileOrder()

    /// A-to-Z for names, newest first for dates: what a key starts with.
    static func initial(_ key: Key) -> FileOrder {
        FileOrder(key: key, ascending: key == .name)
    }

    /// The date this order shows beside a row, if it sorts by one.
    func date(of node: FileNode) -> Date? {
        switch key {
        case .name: nil
        case .modified: node.modified
        case .created: node.created
        }
    }

    func sorted(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted { first, second in
            if first.isDirectory != second.isDirectory { return first.isDirectory }
            if key != .name {
                switch (date(of: first), date(of: second)) {
                case let (a?, b?) where a != b: return ascending ? a < b : a > b
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            let names = first.name.localizedStandardCompare(second.name)
            // Under a date order names only break ties, always A to Z.
            return key == .name && !ascending ? names == .orderedDescending : names == .orderedAscending
        }
    }
}

/// How the Files screen shows a file.
enum FileKind: Equatable, Sendable {
    case markdown, text, image, pdf, other

    var symbol: String {
        switch self {
        case .markdown: "doc.richtext"
        case .text: "doc.text"
        case .image: "photo"
        case .pdf: "doc.viewfinder"
        case .other: "doc"
        }
    }
}

/// What the reader shows for a file.
enum FileContent: Equatable, Sendable {
    case markdown(String)
    case text(String)
    case image
    case pdf
    /// Not shown here; the reason says why (too large, not text).
    case unavailable(String)
}

/// The barrack's folder as a tree (2026-11-16 request: a Finder-like file
/// browser with a Markdown viewer, beside the "recent outputs" panel that
/// only lists what changed lately). Listing is lazy: a folder is read when
/// it is expanded.
enum FileTree {
    struct Row: Identifiable, Hashable, Sendable {
        let node: FileNode
        let depth: Int

        var id: URL { node.url }
    }

    private static let markdownExtensions: Set = ["md", "markdown", "mdx"]
    private static let imageExtensions: Set = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "icns"]
    private static let textExtensions: Set = [
        "txt", "yaml", "yml", "json", "jsonl", "toml", "ini", "cfg", "conf", "env", "csv", "tsv", "log", "xml", "html", "css",
        "sh", "zsh", "bash", "py", "rb", "js", "ts", "tsx", "jsx", "swift", "rs", "go", "java", "kt", "c", "h", "cpp", "sql",
        "violations", "delivered", "lock", "gitignore", "svg",
    ]

    /// Folders first, then files, each in `order` (Finder's name order by
    /// default). Unreadable folders list as empty.
    static func children(of directory: URL, showHidden: Bool, order: FileOrder = .byName) -> [FileNode] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey, .creationDateKey]
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: options)) ?? []
        return order.sorted(entries.map { entry in
            let values = try? entry.resourceValues(forKeys: keys)
            return FileNode(url: entry.standardizedFileURL, isDirectory: values?.isDirectory ?? false,
                            modified: values?.contentModificationDate, created: values?.creationDate)
        })
    }

    /// The visible rows: `root`'s entries and, under each expanded folder,
    /// its own, indented.
    static func rows(root: URL, expanded: Set<URL>, showHidden: Bool, order: FileOrder = .byName) -> [Row] {
        func walk(_ directory: URL, depth: Int) -> [Row] {
            children(of: directory, showHidden: showHidden, order: order).flatMap { node -> [Row] in
                let row = Row(node: node, depth: depth)
                return node.isDirectory && expanded.contains(node.url) ? [row] + walk(node.url, depth: depth + 1) : [row]
            }
        }
        return walk(root.standardizedFileURL, depth: 0)
    }

    /// The folders between `root` and `file` (to reveal a file in the tree).
    static func ancestors(of file: URL, under root: URL) -> [URL] {
        let base = root.standardizedFileURL.pathComponents
        let parts = file.standardizedFileURL.deletingLastPathComponent().pathComponents
        guard parts.count >= base.count, Array(parts.prefix(base.count)) == base else { return [] }
        return (base.count ..< parts.count).map { count in
            parts[base.count ... count].reduce(root.standardizedFileURL) { $0.appendingPathComponent($1, isDirectory: true).standardizedFileURL }
        }
    }

    /// `file` relative to `root` ("wiki/topics/a.md"), or its name.
    static func relativePath(of file: URL, under root: URL) -> String {
        let base = root.standardizedFileURL.path + "/"
        let path = file.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : file.lastPathComponent
    }

    static func kind(of file: URL) -> FileKind {
        let type = file.pathExtension.lowercased()
        if markdownExtensions.contains(type) { return .markdown }
        if imageExtensions.contains(type) { return .image }
        if type == "pdf" { return .pdf }
        if textExtensions.contains(type) { return .text }
        return .other
    }

    /// What to show: Markdown and text up to `limit` bytes; a file with no
    /// known type is text if it reads as UTF-8 without NUL bytes.
    static func content(of file: URL, limit: Int = AppConstants.Files.maxTextBytes) -> FileContent {
        let kind = kind(of: file)
        if kind == .image { return .image }
        if kind == .pdf { return .pdf }
        let size = ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
        guard size <= limit else {
            return .unavailable("파일이 큽니다(\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))). Finder에서 여세요.")
        }
        guard let data = try? Data(contentsOf: file) else { return .unavailable("읽을 수 없습니다.") }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return .unavailable("미리 볼 수 없는 형식입니다.")
        }
        return kind == .markdown ? .markdown(text) : .text(text)
    }

    /// Files the user may edit here: Markdown and text that aib does not
    /// own as a record or system file, and that is not an AUTO-GROW file
    /// (RULES.md has its own editor under Rules; Wiki stays read-only).
    static func isEditable(_ file: URL, in barrack: URL) -> Bool {
        let kind = kind(of: file)
        guard kind == .markdown || kind == .text else { return false }
        switch Ownership.of(file, in: barrack) {
        case nil, .user?: return true
        case .grow?, .record?, .system?: return false
        }
    }
}
