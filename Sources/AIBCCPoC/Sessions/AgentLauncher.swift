import Darwin
import Foundation

/// Starting agents the way CC v1.6.1 does: `aib start <client>` in the
/// barrack, so aib's session tracking and hooks apply. The pane's login
/// shell stays after the agent exits.
enum AgentClient: String, CaseIterable, Identifiable, Sendable {
    case claude, codex, gemini, terminal

    var id: String { rawValue }
    var label: String { self == .terminal ? "터미널" : rawValue.capitalized }
    var symbol: String { self == .terminal ? "terminal" : "sparkles" }
}

enum AgentLauncher {
    /// nil = a plain login shell (the "터미널" choice). `profile` adds the
    /// client's model / effort (v1 Provider profiles).
    static func command(for client: AgentClient, skipPermissions: Bool, profile: ProviderProfile = ProviderProfile()) -> String? {
        guard client != .terminal else { return nil }
        let start = ["aib", "start", client.rawValue] + (skipPermissions ? ["--skip-permissions"] : [])
            + ProviderProfiles.arguments(profile, for: client).map(shellQuote)
        // Ghostty execs `command` without a shell: wrap in a login shell
        // (the user's PATH finds aib) and keep the shell after the agent.
        let inner = start.joined(separator: " ") + "; exec /bin/zsh -l"
        return "/bin/zsh -lc " + shellQuote(inner)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Acknowledging a `done` run, byte-compatible with CC v1.6.1 `write_ack`:
/// `sessions/.live/<id>.ack` = {version, acked_run_id, ack_ts}, atomic.
/// Never used for `blocked` (a waiting agent is not acknowledged away).
enum LivenessAck {
    @discardableResult
    static func write(barrackPath: String, sessionID: String, runID: String,
                      now: Int = Int(Date().timeIntervalSince1970)) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !sessionID.isEmpty, sessionID.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) })
        else { return false }
        let directory = URL(fileURLWithPath: barrackPath).appendingPathComponent("sessions/.live")
        let body: [String: Any] = ["version": 1, "acked_run_id": runID, "ack_ts": now]
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              let data = try? JSONSerialization.data(withJSONObject: body)
        else { return false }
        // Data.write(.atomic) writes a temporary file and renames it.
        return (try? data.write(to: directory.appendingPathComponent("\(sessionID).ack"), options: .atomic)) != nil
    }
}

/// Which pane runs an agent: aib records the agent's pid; a pane owns it
/// if that pid descends from the pane's root process.
enum ProcessTree {
    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func isDescendant(_ pid: pid_t, of root: pid_t) -> Bool {
        var current = pid
        for _ in 0..<64 {
            if current == root { return true }
            guard current > 1, let next = parent(of: current), next != current else { return false }
            current = next
        }
        return false
    }
}
