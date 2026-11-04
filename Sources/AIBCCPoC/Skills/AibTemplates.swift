import Foundation

/// The skills aib seeds into every barrack (`$TEMPLATE_DIR/skills/<slug>`):
/// `aib sync` re-creates one that is missing, so deleting or renaming it
/// from the GUI would be undone by the sync that follows (r5).
enum AibTemplates {
    /// `TEMPLATE_DIR="…"` in the installed aib script.
    static func templateDirectory(fromScript text: String) -> URL? {
        guard let path = text.split(separator: "\n").lazy
            .compactMap({ Regex.capture(#"^TEMPLATE_DIR="([^"$`]+)"\s*$"#, String($0))?[1] }).first else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func skills(in templates: URL) -> Set<String> {
        let directory = templates.appendingPathComponent("skills")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0)/SKILL.md").path) })
    }

    /// Empty when aib or its templates cannot be found.
    static func defaultSkills() async -> Set<String> {
        let found = await ProcessOutput.run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v aib"], in: NSHomeDirectory())
        let path = found.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard path.hasPrefix("/"), let script = try? String(contentsOfFile: path, encoding: .utf8),
              let templates = templateDirectory(fromScript: script) else { return [] }
        return skills(in: templates)
    }
}
