import Foundation

/// Editing barrack documents within aib's contract: only the user-facing
/// files of the rules destination (USER-OWNED, and AUTO-GROW RULES.md);
/// Wiki stays read-only and RECORD/SYSTEM files are never written.
enum DocumentEditing {
    enum SaveResult: Equatable { case saved, unchanged, conflict, failed }

    static func isEditable(_ file: URL, in barrack: URL, destination: Destination) -> Bool {
        guard destination == .rules, let ownership = Ownership.of(file, in: barrack) else { return false }
        return ownership == .user || ownership == .grow
    }

    /// Writes `edited` only if the file still holds `original` — an agent
    /// may append to RULES.md while the user types. Atomic; untouched text
    /// is written back byte for byte.
    static func save(edited: String, original: String, to file: URL) -> SaveResult {
        guard edited != original else { return .unchanged }
        guard let current = try? String(contentsOf: file, encoding: .utf8) else { return .failed }
        guard current == original else { return .conflict }
        return (try? Data(edited.utf8).write(to: file, options: .atomic)) != nil ? .saved : .failed
    }

    static func overwrite(edited: String, to file: URL) -> SaveResult {
        (try? Data(edited.utf8).write(to: file, options: .atomic)) != nil ? .saved : .failed
    }
}
