import Foundation
import Observation

/// A newer aib (2026-11-25: aib had no update check — a Mac stayed on
/// Homebrew's 1.3.4 while 1.6.1 was out). Checked with the app's own update
/// check; offered in the sidebar as a button that runs `aib update` in a
/// terminal pane, where aib asks and updates through Homebrew.
@MainActor
@Observable
final class AibUpdate {
    static let shared = AibUpdate()
    static let latest = URL(string: "https://api.github.com/repos/ai-barracks/ai-barracks/releases/latest")
    /// Tests point the check at a local feed.
    static let feedOverrideKey = "AIBCC_AIB_FEED"
    /// aib 1.6.2 brought `aib update` (asks, then Homebrew); an older aib
    /// does not know it, so the button runs Homebrew itself — the official
    /// tap by full name (an older tap may hold the same formula name).
    static let command = "aib update"
    static let homebrewCommand = "brew update && brew upgrade ai-barracks/ai-barracks/ai-barracks"
    static let firstWithUpdate = ReleaseVersion("1.6.2")

    static func command(installed: ReleaseVersion?) -> String {
        guard let installed, let first = firstWithUpdate, installed >= first else { return homebrewCommand }
        return command
    }

    /// The aib the user's shell runs ("aib version"), and the newest release.
    private(set) var installed: ReleaseVersion?
    private(set) var newest: ReleaseVersion?
    @ObservationIgnored private var watch: Task<Void, Never>?

    var available: ReleaseVersion? { Self.offer(installed: installed, newest: newest) }

    static func offer(installed: ReleaseVersion?, newest: ReleaseVersion?) -> ReleaseVersion? {
        guard let installed, let newest, newest > installed else { return nil }
        return newest
    }

    static var feed: URL? {
        ProcessInfo.processInfo.environment[feedOverrideKey].flatMap(URL.init(string:)) ?? latest
    }

    /// "v1.6.2" → 1.6.2 from a GitHub release.
    static func parse(_ data: Data) -> ReleaseVersion? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        return ReleaseVersion(tag)
    }

    func refreshInstalled() async {
        let output = await AibShell.run("aib version", in: NSHomeDirectory())
        installed = AppVersion.cliVersion(in: output).flatMap(ReleaseVersion.init)
    }

    /// Both versions; a failed lookup keeps what was known.
    func check(feed: URL? = AibUpdate.feed) async {
        await refreshInstalled()
        guard let feed else { return }
        var request = URLRequest(url: feed, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AIBCommandCenter", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return }
        if let version = Self.parse(data) { newest = version }
    }

    /// After the button: reread the installed aib until it is the newest
    /// (or a while passed), so the sidebar stops offering it.
    func watchInstall() {
        watch?.cancel()
        watch = Task { @MainActor [weak self] in
            for _ in 0..<AppConstants.Update.aibWatchRounds {
                try? await Task.sleep(for: AppConstants.Update.aibWatchInterval)
                guard let self, !Task.isCancelled else { return }
                await self.refreshInstalled()
                if self.available == nil { return }
            }
        }
    }
}
