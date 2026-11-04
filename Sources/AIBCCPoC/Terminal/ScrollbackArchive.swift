import Foundation

/// One archived terminal output (v1 scrollback meta sidecar).
struct ArchivedOutput: Codable, Equatable, Identifiable {
    var schemaVersion = ScrollbackArchive.schemaVersion
    let id: String
    let title: String
    let barrackPath: String?
    let closedAt: Date
    let byteLength: Int
    let truncated: Bool
    /// The immutable payload file this record commits to (`<id>.<rev>.txt`).
    var payload: String?
}

/// Terminal output kept on disk after a pane closes or its program ends
/// (v1 scrollback.rs): an immutable payload `<id>.<rev>.txt` and the record
/// `<id>.json` that names it, in a private directory. The record's atomic
/// rename is the commit — a crash between the two writes leaves the
/// previous record and payload intact (r5); unreferenced payloads are
/// garbage. The tail is kept within a per-output cap; old and excess
/// outputs are collected. v2 stores the screen text (what
/// the export writes), not raw PTY bytes, so there is no escape sequence to
/// sanitize on replay.
struct ScrollbackArchive {
    static let schemaVersion = 1
    let directory: URL
    var maxBytesPerOutput = AppConstants.Scrollback.maxBytesPerOutput
    var maxTotalBytes = AppConstants.Scrollback.maxTotalBytes
    var retention = AppConstants.Scrollback.retention

    /// The app's archive; self-tests get their own so they never touch it.
    static var standard: ScrollbackArchive {
        let base = (AppConstants.Daemon.supportDirectory as NSString).expandingTildeInPath
        let name = AppSettings.isSelfTest ? AppConstants.Scrollback.selfTestDirectory : AppConstants.Scrollback.directory
        return ScrollbackArchive(directory: URL(fileURLWithPath: base).appendingPathComponent(name, isDirectory: true))
    }

    /// Saves (or replaces) the output `id`; empty output is not kept.
    @discardableResult
    func save(id: String, title: String, barrackPath: String?, text: String, now: Date = Date()) -> ArchivedOutput? {
        guard Self.isValid(id), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prepareDirectory() else { return nil }
        let (kept, truncated) = Self.tail(text, maxBytes: maxBytesPerOutput)
        let payload = "\(id).\(UUID().uuidString.prefix(8)).txt"
        let entry = ArchivedOutput(id: id, title: title, barrackPath: barrackPath, closedAt: now,
                                   byteLength: kept.utf8.count, truncated: truncated, payload: payload)
        let previous = record(id)?.payload
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let meta = try? encoder.encode(entry), writePrivate(Data(kept.utf8), to: directory.appendingPathComponent(payload)) else { return nil }
        guard writePrivate(meta, to: metaURL(id)) else {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(payload))
            return nil
        }
        if let previous, previous != payload { try? FileManager.default.removeItem(at: directory.appendingPathComponent(previous)) }
        return entry
    }

    /// The committed record of `id`, if its payload exists.
    func record(_ id: String) -> ArchivedOutput? {
        guard Self.isValid(id), let data = try? Data(contentsOf: metaURL(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let entry = try? decoder.decode(ArchivedOutput.self, from: data), entry.id == id,
              let payload = Self.payloadName(of: entry), FileManager.default.fileExists(atPath: directory.appendingPathComponent(payload).path)
        else { return nil }
        return entry
    }

    /// A record's payload file name, only if it is one of this id's names.
    static func payloadName(of entry: ArchivedOutput) -> String? {
        let name = entry.payload ?? entry.id + ".txt"
        return Regex.matches("^\(entry.id)(\\.[0-9A-F]{8})?\\.txt$", name) ? name : nil
    }

    /// Newest first; unreadable or foreign files are skipped.
    func list() -> [ArchivedOutput] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { record(String($0.dropLast(5))) }
        // Ties (same millisecond) break by id: GC must be deterministic.
        .sorted { $0.closedAt == $1.closedAt ? $0.id > $1.id : $0.closedAt > $1.closedAt }
    }

    func text(of id: String) -> String? {
        guard let entry = record(id), let payload = Self.payloadName(of: entry),
              let data = try? Data(contentsOf: directory.appendingPathComponent(payload)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The record first (it is the commit), then every payload of the id.
    func delete(_ id: String) {
        guard Self.isValid(id) else { return }
        try? FileManager.default.removeItem(at: metaURL(id))
        payloads(of: id).forEach { try? FileManager.default.removeItem(at: directory.appendingPathComponent($0)) }
    }

    private func payloads(of id: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(id + ".") && $0.hasSuffix(".txt") }
    }

    func deleteAll() {
        list().forEach { delete($0.id) }
    }

    /// Drops outputs older than the retention, then the oldest until the
    /// total fits the cap. Returns how many were removed.
    @discardableResult
    func collectGarbage(now: Date = Date()) -> Int {
        var removed = 0
        var kept: [ArchivedOutput] = []
        for entry in list() {
            if now.timeIntervalSince(entry.closedAt) > retention {
                delete(entry.id)
                removed += 1
            } else {
                kept.append(entry)
            }
        }
        var total = kept.reduce(0) { $0 + $1.byteLength }
        var survivors = Set(kept.compactMap(Self.payloadName))
        for entry in kept.reversed() where total > maxTotalBytes {
            delete(entry.id)
            total -= entry.byteLength
            removed += 1
            if let name = Self.payloadName(of: entry) { survivors.remove(name) }
        }
        // Payloads no record commits to (an interrupted save).
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasSuffix(".txt") && !name.hasPrefix(".") && !survivors.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        return removed
    }

    /// The last `maxBytes` of `text`, starting after the first line break
    /// inside the kept part (no half line) and on a character boundary.
    static func tail(_ text: String, maxBytes: Int) -> (String, Bool) {
        let bytes = Array(text.utf8)
        guard bytes.count > maxBytes else { return (text, false) }
        var start = bytes.count - maxBytes
        while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
        if let newline = bytes[start...].firstIndex(of: UInt8(ascii: "\n")), newline + 1 < bytes.count { start = newline + 1 }
        return (String(decoding: bytes[start...], as: UTF8.self), true)
    }

    /// Ids are UUID strings: nothing else can name a file here.
    static func isValid(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    private func metaURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".json") }

    /// Owner-only directory: terminal output can hold secrets.
    private func prepareDirectory() -> Bool {
        let manager = FileManager.default
        if (try? manager.attributesOfItem(atPath: directory.path))?[.type] as? FileAttributeType == .typeSymbolicLink { return false }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return true
        } catch {
            return false
        }
    }

    /// Owner-only file written to a temp name, then renamed over the target.
    private func writePrivate(_ data: Data, to url: URL) -> Bool {
        let temp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        guard rename(temp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        return true
    }
}
