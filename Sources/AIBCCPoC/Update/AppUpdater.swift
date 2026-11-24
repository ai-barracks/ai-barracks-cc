import AppKit
import Observation

/// 앱 안 업데이트 (2026-11-24, user: updating by DMG + xattr every release
/// is a chore). Checks GitHub's latest release at launch and daily, shows
/// it in the sidebar, and on the user's word installs it and relaunches.
/// Agents and terminals live in the PTY daemon, so they keep running and
/// reattach after the relaunch.
@MainActor
@Observable
final class AppUpdater {
    enum State: Equatable {
        case idle, checking, upToDate, installing
        case available(ReleaseInfo)
        case failed(String)
    }

    static let shared = AppUpdater()
    static let autoCheckKey = "update.autoCheck"
    static let bundleID = "com.aibarracks.commandcenter2"

    private(set) var state: State = .idle
    private(set) var lastChecked: Date?
    /// Why the last install did not happen (the release stays offered).
    private(set) var installError: String?
    /// The release the user is being asked about.
    var confirming: ReleaseInfo?
    @ObservationIgnored private var schedule: Task<Void, Never>?

    /// The running app's release version; nil for a development build.
    let current: ReleaseVersion?

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        let label = (info["AIBVersionLabel"] as? String) ?? (info["CFBundleShortVersionString"] as? String) ?? ""
        current = info["CFBundleIdentifier"] as? String == Self.bundleID ? ReleaseVersion(label) : nil
    }

    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoCheckKey) }
    }

    /// Shows `release` as on offer, nil to clear (README pictures; a check
    /// does this for real).
    func offer(_ release: ReleaseInfo?) {
        state = release.map { .available($0) } ?? .idle
    }

    var available: ReleaseInfo? {
        if case let .available(release) = state { return release }
        return nil
    }

    /// Launch, then every day while the app stays open; never in self-tests
    /// or development builds.
    func startAutomaticChecks() {
        guard schedule == nil, current != nil, !AppSettings.isSelfTest else { return }
        schedule = Task { @MainActor [weak self] in
            try? await Task.sleep(for: AppConstants.Update.firstCheckDelay)
            while !Task.isCancelled, let updater = self {
                if updater.autoCheck { await updater.check(userInitiated: false) }
                try? await Task.sleep(for: AppConstants.Update.checkInterval)
            }
        }
    }

    /// `userInitiated`: from the menu or Settings — an answer is shown even
    /// when there is nothing new, and a new release is offered at once.
    func check(userInitiated: Bool, feed: URL? = UpdateFeed.url) async {
        guard state != .installing else { return }
        guard let current, let feed else {
            if userInitiated { state = .failed("개발 빌드는 업데이트를 확인하지 않습니다") }
            return
        }
        state = .checking
        do {
            let release = try await UpdateFeed.fetch(from: feed, userAgent: "AIBCommandCenter/\(current)")
            lastChecked = Date()
            state = release.version > current ? .available(release) : .upToDate
            if userInitiated, release.version > current { confirming = release }
        } catch {
            state = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
        }
    }

    /// Installs over this app and relaunches; on failure the app stays as
    /// it was and says why.
    func install(_ release: ReleaseInfo, target: URL = Bundle.main.bundleURL, relaunch: Bool = true) async -> Bool {
        state = .installing
        installError = nil
        let support = AppConstants.Update.directory
        let plan = UpdateInstaller.Plan(release: release, target: target, bundleID: Self.bundleID,
                                        work: support.appendingPathComponent("download"),
                                        backup: support.appendingPathComponent("previous/\(target.lastPathComponent)"))
        do {
            try await Task.detached { try await UpdateInstaller.install(plan) }.value
        } catch {
            installError = (error as? UpdateError)?.message ?? error.localizedDescription
            state = .available(release)
            return false
        }
        try? FileManager.default.removeItem(at: plan.work)
        if relaunch { Self.relaunch(target) }
        return true
    }

    /// Opens `app` once this process has exited, then quits.
    static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\"", "relaunch", app.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        NSApp.terminate(nil)
    }

    /// Said before installing: what happens to open terminals.
    static var sessionsNote: String {
        let keep = UserDefaults.standard.object(forKey: AppConstants.Daemon.keepSessionsOnQuitKey) as? Bool ?? true
        return keep ? "열린 에이전트·터미널은 계속 실행되고, 다시 켜지면 그대로 이어집니다."
            : "'앱 종료 시 세션 유지'가 꺼져 있어 열린 터미널이 모두 종료됩니다."
    }
}
