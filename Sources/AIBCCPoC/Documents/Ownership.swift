import SwiftUI

/// aib file ownership (barrack CLAUDE.md File Map). The UI shows it as a
/// seal with what the class means and what is allowed (spec §3).
enum Ownership: String, Sendable {
    case user = "USER-OWNED", grow = "AUTO-GROW", record = "RECORD", system = "SYSTEM"

    var meaning: String {
        switch self {
        case .user: "사용자가 배럭에 맞게 고치는 파일"
        case .grow: "에이전트가 학습을 덧붙이며 자라는 파일"
        case .record: "세션이 남긴 기록 — 종료 후 보존"
        case .system: "Hook·CLI가 관리하는 파일"
        }
    }

    var allowed: String {
        switch self {
        case .user: "편집 가능(형식 유지)"
        case .grow: "읽기 · 형식을 지킨 편집"
        case .record: "읽기 전용"
        case .system: "읽기 전용"
        }
    }

    var color: Color {
        switch self {
        case .user: Color(dark: 0x7FA7FF, light: 0x2F5FD0)
        case .grow: Tokens.teal
        case .record: Color(dark: 0xC9A86B, light: 0x8E6A22)
        case .system: Color(dark: 0x8D95A0, light: 0x66707B)
        }
    }

    /// The file's own `AIB:OWNERSHIP — [CLASS]` header wins; otherwise the
    /// File Map by path.
    static func of(_ file: URL, in barrack: URL) -> Ownership? {
        if let head = try? String(contentsOf: file, encoding: .utf8).prefix(300),
           let range = head.range(of: #"AIB:OWNERSHIP — \[([A-Z-]+)\]"#, options: .regularExpression) {
            let tag = head[range].split(separator: "[").last?.dropLast() ?? ""
            if let owned = Ownership(rawValue: String(tag)) { return owned }
        }
        let relative = file.standardizedFileURL.path.replacingOccurrences(of: barrack.standardizedFileURL.path + "/", with: "")
        switch relative {
        case "RULES.md": return .grow
        case "GROWTH.md", "SOUL.md", "agent.yaml": return .user
        case "SESSIONS.md": return .system
        default:
            if relative.hasPrefix("wiki/") { return .grow }
            if relative.hasPrefix("sessions/") { return .record }
            if relative.hasPrefix("docs/") { return .system }
            return nil
        }
    }
}

/// Seal on top of every barrack document: class, meaning, what is allowed.
struct OwnershipSeal: View {
    let ownership: Ownership

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Label(ownership.rawValue, systemImage: "seal.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ownership.color)
            Text(ownership.meaning)
                .foregroundStyle(Tokens.textSecondary)
            Text("· \(ownership.allowed)")
                .foregroundStyle(Tokens.textTertiary)
        }
        .font(Tokens.Font.meta)
        .padding(.horizontal, Tokens.Spacing.s)
        .padding(.vertical, 3)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.row).stroke(ownership.color.opacity(0.45), lineWidth: 0.5))
    }
}
