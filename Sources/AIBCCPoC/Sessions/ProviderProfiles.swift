import Foundation

/// Model and reasoning effort for new sessions of one client (v1 Provider /
/// Model profiles): passed as `aib start <client> --model … --effort …`.
/// Empty = the CLI's runtime default. Existing sessions are not touched.
struct ProviderProfile: Codable, Equatable {
    var model = ""
    var effort = ""
}

enum ProviderProfiles {
    static let clients: [AgentClient] = [.codex, .claude]
    /// Documented Claude Code aliases — not an account availability promise.
    static let claudeAliases = ["sonnet", "opus", "haiku"]
    static let maxModelLength = 200

    /// What `aib start` accepts per client (v1 build_profile_command).
    static func efforts(for client: AgentClient) -> [String] {
        switch client {
        case .claude: ["low", "medium", "high", "max"]
        case .codex: ["none", "minimal", "low", "medium", "high", "xhigh"]
        case .gemini, .terminal: []
        }
    }

    static func isValid(_ profile: ProviderProfile, for client: AgentClient) -> Bool {
        profile.model.count <= maxModelLength
            && !profile.model.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && (profile.effort.isEmpty || efforts(for: client).contains(profile.effort))
            && (clients.contains(client) || profile == ProviderProfile())
    }

    static func key(_ client: AgentClient) -> String { "providerProfile.\(client.rawValue)" }

    /// A stored profile that fails validation is ignored (v1 readProviderProfile).
    static func load(_ client: AgentClient, defaults: UserDefaults = .standard) -> ProviderProfile {
        // Self-tests run on defaults — except a store a test passes in (r5).
        guard defaults !== UserDefaults.standard || !AppSettings.isSelfTest, let data = defaults.data(forKey: key(client)),
              let profile = try? JSONDecoder().decode(ProviderProfile.self, from: data),
              isValid(profile, for: client) else { return ProviderProfile() }
        return profile
    }

    @discardableResult
    static func save(_ profile: ProviderProfile, for client: AgentClient, defaults: UserDefaults = .standard) -> Bool {
        let trimmed = ProviderProfile(model: profile.model.trimmingCharacters(in: .whitespaces), effort: profile.effort)
        guard isValid(trimmed, for: client), let data = try? JSONEncoder().encode(trimmed) else { return false }
        defaults.set(data, forKey: key(client))
        return true
    }

    /// `aib start` arguments for the profile (unquoted; the launcher quotes).
    static func arguments(_ profile: ProviderProfile, for client: AgentClient) -> [String] {
        guard isValid(profile, for: client) else { return [] }
        return (profile.model.isEmpty ? [] : ["--model", profile.model]) + (profile.effort.isEmpty ? [] : ["--effort", profile.effort])
    }

    static func summary(_ profile: ProviderProfile) -> String {
        let model = profile.model.isEmpty ? "기본 모델" : profile.model
        return profile.effort.isEmpty ? model : "\(model) · effort \(profile.effort)"
    }
}
