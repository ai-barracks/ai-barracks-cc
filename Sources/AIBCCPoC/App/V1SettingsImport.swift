import Foundation
import SQLite3

/// Bringing CC v1.6.1 settings over (parity plan I2). v1 keeps them in its
/// WebKit localStorage (an SQLite `ItemTable`, values UTF-16LE), read here
/// read-only: Quick Commands, terminal font size / cursor, model profiles.
/// The activation schedule needs no import — v2 uses v1's file itself.
enum V1SettingsImport {
    struct Found: Equatable {
        var quickCommands: [(label: String, command: String, cwd: String?)] = []
        var fontSize: Double?
        var lineHeight: Double?
        var cursor: String?
        var profiles: [AgentClient: ProviderProfile] = [:]

        var isEmpty: Bool { quickCommands.isEmpty && fontSize == nil && lineHeight == nil && cursor == nil && profiles.isEmpty }

        static func == (lhs: Found, rhs: Found) -> Bool {
            lhs.quickCommands.map { "\($0.label)\u{0}\($0.command)\u{0}\($0.cwd ?? "")" }
                == rhs.quickCommands.map { "\($0.label)\u{0}\($0.command)\u{0}\($0.cwd ?? "")" }
                && lhs.fontSize == rhs.fontSize && lhs.lineHeight == rhs.lineHeight && lhs.cursor == rhs.cursor
                && lhs.profiles == rhs.profiles
        }
    }

    static var websiteData: URL {
        URL(fileURLWithPath: ("~/Library/WebKit/com.aibarracks.commandcenter/WebsiteData" as NSString).expandingTildeInPath)
    }

    /// `Default/<origin>/<origin>/LocalStorage/localstorage.sqlite3` files.
    static func storeFiles(under root: URL = websiteData) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            $0.lastPathComponent == "localstorage.sqlite3" && $0.deletingLastPathComponent().lastPathComponent == "LocalStorage"
        }
    }

    /// key → value, opened read-only (v1 may be running).
    static func items(in file: URL) -> [String: String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM ItemTable", -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = sqlite3_column_text(statement, 0), let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            result[String(cString: key)] = String(data: data, encoding: .utf16LittleEndian)
        }
        return result
    }

    /// What v1 stored that v2 can use; anything malformed is skipped.
    static func parse(_ items: [String: String]) -> Found {
        var found = Found()
        let json = { (key: String) in items[key].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } }
        if let commands = json("cc-quick-commands") as? [[String: Any]] {
            found.quickCommands = commands.compactMap { item in
                guard let command = (item["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { return nil }
                let folder = (item["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return ((item["label"] as? String) ?? command, command, folder)
            }
        }
        if let settings = json("cc-terminal-settings") as? [String: Any] {
            found.fontSize = (settings["fontSize"] as? Double).map { min(max($0, AppSettings.fontSizeRange.lowerBound), AppSettings.fontSizeRange.upperBound) }
            found.lineHeight = (settings["lineHeight"] as? Double).map(AppSettings.clampedLineHeight)
            found.cursor = (settings["cursorStyle"] as? String).flatMap { ["block", "bar", "underline"].contains($0) ? $0 : nil }
        }
        for client in ProviderProfiles.clients {
            guard let value = items["aib-profile-\(client.rawValue)"],
                  let profile = try? JSONDecoder().decode(ProviderProfile.self, from: Data(value.utf8)),
                  profile != ProviderProfile(), ProviderProfiles.isValid(profile, for: client) else { continue }
            found.profiles[client] = profile
        }
        return found
    }

    static func find() -> Found {
        storeFiles().map { parse(items(in: $0)) }.first { !$0.isEmpty } ?? Found()
    }

    /// v1 commands are told apart by command and folder. An entry an earlier
    /// import brought in without its folder (same name and command, no
    /// folder) gets v1's folder; anything else that differs is added, so a
    /// folder the user set is never overwritten (Codex review of P03).
    static func mergeQuickCommands(
        _ incoming: [(label: String, command: String, cwd: String?)], into existing: [QuickCommand]
    ) -> (updates: [QuickCommand], additions: [(label: String, command: String, cwd: String?)]) {
        var current = existing
        var updates: [QuickCommand] = []
        var additions: [(label: String, command: String, cwd: String?)] = []
        for item in incoming {
            if current.contains(where: { $0.command == item.command && $0.cwd == item.cwd }) { continue }
            if let folder = item.cwd,
               let index = current.firstIndex(where: { $0.command == item.command && $0.label == item.label && $0.cwd == nil }) {
                var filled = current[index]
                filled.cwd = folder
                current[index] = filled
                updates.append(filled)
                continue
            }
            additions.append(item)
            current.append(QuickCommand(label: item.label, command: item.command, cwd: item.cwd))
        }
        return (updates, additions)
    }

    /// Adds Quick Commands not already present and sets the rest.
    @MainActor
    static func apply(_ found: Found, quickCommands: QuickCommandStore, defaults: UserDefaults = .standard) -> [String] {
        var applied: [String] = []
        let merge = mergeQuickCommands(found.quickCommands, into: quickCommands.commands)
        merge.updates.forEach { quickCommands.upsert($0) }
        merge.additions.forEach { quickCommands.add(label: $0.label, command: $0.command, cwd: $0.cwd) }
        if !merge.additions.isEmpty { applied.append("Quick Commands \(merge.additions.count)개") }
        if !merge.updates.isEmpty { applied.append("Quick Command 폴더 \(merge.updates.count)개 보완") }
        if let size = found.fontSize {
            defaults.set(size, forKey: AppSettings.fontSizeKey)
            applied.append("글꼴 \(Int(size))pt")
        }
        if let height = found.lineHeight {
            defaults.set(height, forKey: AppSettings.lineHeightKey)
            applied.append("줄 간격 \(String(format: "%.1f", height))")
        }
        if let cursor = found.cursor {
            defaults.set(cursor, forKey: AppSettings.cursorKey)
            applied.append("커서 \(cursor)")
        }
        for (client, profile) in found.profiles where ProviderProfiles.save(profile, for: client, defaults: defaults) {
            applied.append("\(client.label) 모델 \(ProviderProfiles.summary(profile))")
        }
        return applied
    }
}
