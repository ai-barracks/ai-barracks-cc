import Foundation
import SQLite3

/// v1 settings import on a WebKit-shaped localStorage file in a temp dir.
@MainActor
struct V1ImportSuite {
    func run() -> TestResult {
        let start = ContinuousClock.now
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-v1import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Default/abc/abc/LocalStorage")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("localstorage.sqlite3")
        var failures: [String] = []
        write(file, [
            "cc-quick-commands": #"[{"id":"1","label":"build","command":"npm run build"},{"id":"2","label":"x","command":"  "},{"id":"3","label":"dup","command":"git status"}]"#,
            "cc-terminal-settings": #"{"fontFamily":"Menlo","fontSize":30,"lineHeight":1.2,"cursorStyle":"underline"}"#,
            "aib-profile-codex": #"{"model":"gpt-6-sol","effort":"high"}"#,
            "aib-profile-claude": #"{"model":"","effort":""}"#,
            "cc-theme": "dark",
        ])
        let files = V1SettingsImport.storeFiles(under: root)
        if files.map(\.lastPathComponent) != ["localstorage.sqlite3"] { failures.append("store file") }
        let found = V1SettingsImport.parse(files.first.map(V1SettingsImport.items) ?? [:])
        if found.quickCommands.map(\.command) != ["npm run build", "git status"] { failures.append("quick \(found.quickCommands.map(\.command))") }
        if found.fontSize != AppSettings.fontSizeRange.upperBound || found.cursor != "underline" { failures.append("terminal") }
        if found.profiles != [.codex: ProviderProfile(model: "gpt-6-sol", effort: "high")] { failures.append("profiles") }
        let defaults = UserDefaults(suiteName: "aibcc-v1import-\(UUID().uuidString)")!
        let store = QuickCommandStore(defaults: defaults)
        store.add(label: "existing", command: "git status")
        let applied = V1SettingsImport.apply(found, quickCommands: store, defaults: defaults)
        if store.commands.map(\.command) != ["git status", "npm run build"] { failures.append("dedupe \(store.commands.map(\.command))") }
        if defaults.double(forKey: AppSettings.fontSizeKey) != AppSettings.fontSizeRange.upperBound
            || defaults.string(forKey: AppSettings.cursorKey) != "underline" { failures.append("applied terminal") }
        if ProviderProfiles.load(.codex, defaults: defaults) != found.profiles[.codex] { failures.append("profile") }
        if applied.count != 4 { failures.append("applied \(applied)") }
        if !V1SettingsImport.parse(["cc-quick-commands": "not json", "aib-profile-codex": #"{"model":"m","effort":"bogus"}"#]).isEmpty {
            failures.append("malformed accepted")
        }
        return .make("V1-01a", "v1 설정 가져오기(WebKit localStorage 읽기 전용: Quick Commands·터미널·모델 프로필, 중복·잘못된 값 제외)",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    private func write(_ file: URL, _ items: [String: String]) {
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB NOT NULL ON CONFLICT FAIL)", nil, nil, nil)
        for (key, value) in items {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO ItemTable VALUES (?, ?)", -1, &statement, nil)
            let data = value.data(using: .utf16LittleEndian) ?? Data()
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, key, -1, transient)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }
}
