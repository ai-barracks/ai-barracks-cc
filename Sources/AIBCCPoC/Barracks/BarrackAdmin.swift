import Foundation

/// Registering and unregistering barracks through aib (v1 create_barrack,
/// remove_barrack, refresh_barracks). The registry file changes and the
/// workspace's registry watcher picks the new list up.
enum BarrackAdmin {
    struct Outcome: Equatable {
        let ok: Bool
        let output: String
    }

    /// `aib init <path>` then `aib sync <path>`: init scaffolds the missing
    /// core files (existing ones are skipped), registers the barrack and
    /// makes sure the Claude Code / Gemini CLI hooks are in their settings
    /// (~/.claude/settings.json); sync adds what init leaves out (GROWTH.md,
    /// docs/, the default skills) so a new barrack matches the others. v1
    /// ran init only.
    static func create(at path: String, environment: [String: String] = [:]) async -> Outcome {
        let quoted = AgentLauncher.shellQuote(path)
        let initialized = await aib("init \(quoted)", environment: environment)
        guard initialized.ok else { return initialized }
        let synced = await aib("sync \(quoted)", environment: environment)
        return Outcome(ok: synced.ok, output: initialized.output + "\n" + synced.output)
    }

    /// `aib barracks remove <path>`: unregisters only; no file is deleted.
    static func remove(_ path: String, environment: [String: String] = [:]) async -> Outcome {
        await aib("barracks remove \(AgentLauncher.shellQuote(path))", environment: environment)
    }

    /// `aib barracks refresh`: re-reads every barrack's metadata and drops
    /// entries whose directory is gone.
    static func refresh(environment: [String: String] = [:]) async -> Outcome {
        await aib("barracks refresh", environment: environment)
    }

    /// Files `aib init` creates when missing, shown before it runs.
    static let scaffold = "SESSIONS.md, sessions/, wiki/, SOUL.md, RULES.md, GROWTH.md, agent.yaml, CLAUDE.md·AGENTS.md·GEMINI.md, docs/, skills/council, .gitignore"

    private static func aib(_ arguments: String, environment: [String: String]) async -> Outcome {
        let result = await ProcessOutput.runWithStatus(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "aib \(arguments)"],
                                                       in: NSHomeDirectory(), environment: environment)
        let output = MaintenanceScanner.lines(result.output).joined(separator: "\n")
        return Outcome(ok: result.status == 0, output: output)
    }
}
