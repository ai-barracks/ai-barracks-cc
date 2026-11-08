import CryptoKit
import Foundation

/// aib session records (`sessions/<id>.md`), parsed exactly like CC v1.6.1
/// `commands/sessions.rs`: `**Field**: value` header fields and `## Section`
/// bullet lists, plus the seal check `aib sessions verify` performs.
struct SessionRecord: Identifiable, Sendable, Equatable {
    let id: String
    let client: String
    let started: String
    let ended: String
    let status: String
    let task: String
    let continues: String

    var canContinue: Bool { status == "completed" || status == "interrupted" }
    /// "claude" / "codex" / "gemini" for `aib start`.
    var clientKey: String { client.lowercased().split(separator: " ").first.map(String.init) ?? "" }
    /// v1 "empty": not running and never given a task (v1 SessionsTab).
    var isEmpty: Bool {
        let trimmed = task.trimmingCharacters(in: .whitespaces)
        return status != "active" && (trimmed.isEmpty || trimmed == "(pending)")
    }
}

struct SessionDetail: Sendable, Equatable {
    enum Seal: String, Sendable { case intact, modified, unsealed, invalid }

    let record: SessionRecord
    let log: [String]
    let decisions: [String]
    let blockers: [String]
    let wikiExtractions: [String]
    let identitySuggestions: [String]
    let raw: String
    let seal: Seal
    let violations: String?
}

enum SHA256Hex {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum SessionRecords {
    static func list(barrackPath: String) -> [SessionRecord] {
        let directory = URL(fileURLWithPath: barrackPath).appendingPathComponent("sessions")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".md") }.compactMap { name in
            let id = String(name.dropLast(3))
            let text = (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return record(id: id, text: text)
        }
        .sorted { $0.id > $1.id }
    }

    /// Count only (the sidebar badge): no file is read.
    static func count(barrackPath: String) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: barrackPath + "/sessions")) ?? []
        return names.filter { $0.hasSuffix(".md") }.count
    }

    static func detail(barrackPath: String, id: String) -> SessionDetail? {
        let barrack = URL(fileURLWithPath: barrackPath)
        let file = barrack.appendingPathComponent("sessions/\(id).md")
        // Seal read before and after: if SessionEnd sealed in between,
        // re-read so old bytes are not compared with the new seal.
        var seal = readSeal(barrack: barrack, id: id)
        guard var bytes = try? Data(contentsOf: file) else { return nil }
        let sealAfter = readSeal(barrack: barrack, id: id)
        if sealAfter != seal {
            seal = sealAfter
            bytes = (try? Data(contentsOf: file)) ?? bytes
        }
        let isSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil
        let text = String(decoding: bytes, as: UTF8.self)
        let violations = try? String(contentsOf: barrack.appendingPathComponent("sessions/\(id).violations"), encoding: .utf8)
        return SessionDetail(
            record: record(id: id, text: text),
            log: section("Log", in: text), decisions: section("Decisions", in: text),
            blockers: section("Blockers", in: text), wikiExtractions: section("Wiki Extractions", in: text),
            identitySuggestions: section("Identity Suggestions", in: text), raw: text,
            seal: sealStatus(seal, id: id, bytes: bytes, isSymlink: isSymlink), violations: violations
        )
    }

    static func record(id: String, text: String) -> SessionRecord {
        let client = field("Client", in: text)
        return SessionRecord(id: id, client: client.isEmpty ? detectClient(id) : client,
                             started: field("Started", in: text), ended: field("Ended", in: text),
                             status: field("Status", in: text), task: field("Task", in: text),
                             continues: field("Continues", in: text))
    }

    static func field(_ name: String, in text: String) -> String {
        let pattern = "\\*\\*" + NSRegularExpression.escapedPattern(for: name) + "\\*\\*:[ \\t]*(.+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return "" }
        return text[range].trimmingCharacters(in: .whitespaces)
    }

    static func section(_ name: String, in text: String) -> [String] {
        var inside = false
        var items: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("## \(name)") {
                inside = true
                continue
            }
            if inside && line.hasPrefix("## ") { break }
            guard inside else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                items.append(String(trimmed.dropFirst(2)))
            } else if !trimmed.isEmpty && !trimmed.hasPrefix("<!--") {
                items.append(trimmed)
            }
        }
        return items
    }

    static func detectClient(_ id: String) -> String {
        if id.hasPrefix("claude") { return "Claude Code" }
        if id.hasPrefix("gemini") { return "Gemini CLI" }
        if id.hasPrefix("codex") { return "Codex CLI" }
        return "Unknown"
    }

    // MARK: - Seal (`sessions/.seals/<id>.sha256`, one shasum line)

    enum SealRead: Equatable { case missing, unusable, record(String) }

    static func readSeal(barrack: URL, id: String) -> SealRead {
        let directory = barrack.appendingPathComponent("sessions/.seals")
        guard let dirType = fileType(directory) else { return .missing }
        guard dirType == .typeDirectory else { return .unusable }
        let seal = directory.appendingPathComponent("\(id).sha256")
        guard let type = fileType(seal) else { return .missing }
        guard type == .typeRegular, let content = try? String(contentsOf: seal, encoding: .utf8) else { return .unusable }
        return .record(content)
    }

    /// A seal that exists but cannot be used is `invalid`, never `unsealed`,
    /// so breaking the seal does not hide a change (as v1 and aib).
    static func sealStatus(_ seal: SealRead, id: String, bytes: Data, isSymlink: Bool) -> SessionDetail.Seal {
        let record: String
        switch seal {
        case .missing: return .unsealed
        case .unusable: return .invalid
        case let .record(content): record = content.hasSuffix("\n") ? String(content.dropLast()) : content
        }
        if isSymlink { return .invalid }
        let parts = record.components(separatedBy: "  ")
        guard !record.contains("\n"), parts.count == 2, parts[1] == "sessions/\(id).md",
              parts[0].count == 64, parts[0].allSatisfy({ "0123456789abcdef".contains($0) })
        else { return .invalid }
        let actual = SHA256Hex.of(bytes)
        return parts[0] == actual ? .intact : .modified
    }

    private static func fileType(_ url: URL) -> FileAttributeType? {
        // attributesOfItem does not follow symlinks (lstat).
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    // MARK: - Actions (CC v1.6.1 parity)

    static func continueCommand(client: String, sessionID: String, skipPermissions: Bool = false) -> String {
        let prompt = "이전 세션 \(sessionID)의 작업을 이어서 진행해주세요. sessions/\(sessionID).md 파일을 읽고 작업을 계속하세요."
        let start = ["aib", "start", client] + (skipPermissions ? ["--skip-permissions"] : [])
        return (start + [AgentLauncher.shellQuote(prompt)]).joined(separator: " ")
    }

    static func monitorCommand(sessionID: String) -> String {
        let file = AgentLauncher.shellQuote("sessions/\(sessionID).md")
        return "while true; do clear; printf '=== %s (3초마다 새로고침, Ctrl+C로 종료) ===\\n' "
            + AgentLauncher.shellQuote(sessionID) + "; tail -30 \(file); sleep 3; done"
    }
}
