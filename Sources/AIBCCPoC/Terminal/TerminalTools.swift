import Foundation
import Observation

/// Quick Commands (CC v1.6.1 parity): saved commands run in the focused
/// terminal as if typed. Stored per user, like v1's local storage.
struct QuickCommand: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var label: String
    var command: String
}

@MainActor
@Observable
final class QuickCommandStore {
    private(set) var commands: [QuickCommand]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "quickCommands"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        commands = defaults.data(forKey: "quickCommands").flatMap { try? JSONDecoder().decode([QuickCommand].self, from: $0) } ?? []
    }

    func add(label: String, command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commands = commands + [QuickCommand(label: label.isEmpty ? trimmed : label, command: trimmed)]
        save()
    }

    func remove(_ id: QuickCommand.ID) {
        commands = commands.filter { $0.id != id }
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(commands), forKey: key)
    }
}

/// Ghostty's `text:` binding sends a string to the PTY as if typed; its
/// value is a Zig string literal body.
enum GhosttyText {
    static func action(typing text: String, pressEnter: Bool) -> String {
        "text:" + escape(text) + (pressEnter ? "\\r" : "")
    }

    static func escape(_ text: String) -> String {
        text.unicodeScalars.map { scalar -> String in
            switch scalar {
            case "\\": return "\\\\"
            case "\"": return "\\\""
            case "\n": return "\\n"
            case "\r": return "\\r"
            case "\t": return "\\t"
            default:
                return scalar.value < 0x20 || scalar.value == 0x7F ? String(format: "\\x%02x", scalar.value) : String(scalar)
            }
        }.joined()
    }
}

/// "Export output" (v1 write_session_export): the terminal's text as
/// `<barrack>/sessions/terminal-<title>-<time>.txt`, written only inside
/// the barrack's sessions folder and never through a symlink.
enum TerminalExport {
    enum Failure: Error, Equatable { case empty, outside, exists, write }

    static func fileName(title: String, now: Date) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let safe = String(title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return "terminal-\(safe)-\(formatter.string(from: now)).txt"
    }

    static func write(_ text: String, barrackPath: String, title: String, now: Date = Date()) -> Result<URL, Failure> {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.empty) }
        let root = URL(fileURLWithPath: barrackPath).resolvingSymlinksInPath()
        let sessions = root.appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let resolved = sessions.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") else { return .failure(.outside) }
        let target = resolved.appendingPathComponent(fileName(title: title, now: now))
        // attributesOfItem does not follow a symlink: any entry is refused.
        guard (try? FileManager.default.attributesOfItem(atPath: target.path)) == nil else { return .failure(.exists) }
        return (try? Data(text.utf8).write(to: target, options: [.withoutOverwriting])) != nil ? .success(target) : .failure(.write)
    }
}
