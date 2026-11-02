import Foundation
import Observation

/// v1's 30-second checks (stale sessions, sync needed) plus v2's attention
/// notices. Reads files off the main thread; posts on it.
@MainActor
final class HealthMonitor {
    private let workspace: WorkspaceModel
    private let notices: NoticeCenter
    private var timer: Timer?
    private var notifiedStale: [String: Date] = [:]
    private var lastSync: (signature: String, at: Date)?
    private(set) var outdatedBarracks: [String] = []
    private(set) var cliVersion = ""

    init(workspace: WorkspaceModel, notices: NoticeCenter) {
        self.workspace = workspace
        self.notices = notices
    }

    func start() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: AppConstants.Health.firstCheckDelay)
            await self?.check()
            self?.timer = Timer.scheduledTimer(withTimeInterval: AppConstants.Health.interval, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.check() }
            }
        }
    }

    func check() async {
        await checkStale()
        await checkSync()
    }

    private func checkStale() async {
        let barracks = workspace.barracks
        let now = Date()
        let stale = await Task.detached { HealthMonitor.staleSessions(barracks, now: now) }.value
        var seen = Set<String>()
        for (barrack, session, hours) in stale {
            let key = "\(barrack.path):\(session.id)"
            seen.insert(key)
            guard HealthRules.shouldNotify(key: key, notified: notifiedStale, now: now) else { continue }
            notifiedStale[key] = now
            notices.post(AppNotice(kind: .stale, title: "Stale: \(barrack.name)",
                                   body: "\(session.client) idle \(hours)h — \(session.task)", actionLabel: "기록 보기",
                                   barrackID: barrack.id, sessionID: session.id))
        }
        notifiedStale = notifiedStale.filter { seen.contains($0.key) }
    }

    private func checkSync() async {
        let barracks = workspace.barracks
        guard let first = barracks.first else { return }
        let output = await AibShell.run("aib version", in: first.path)
        guard let version = output.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression).map({ String(output[$0]) }) else { return }
        let outdated = await Task.detached { HealthMonitor.outdated(barracks, cliVersion: version) }.value
        cliVersion = version
        outdatedBarracks = outdated.map(\.path)
        let names = outdated.map(\.name)
        guard HealthRules.shouldAnnounceSync(outdated: names, cliVersion: version, last: lastSync, now: Date()) else { return }
        lastSync = (HealthRules.syncSignature(outdated: names, cliVersion: version), Date())
        notices.post(AppNotice(kind: .sync, title: "Sync Required",
                               body: "\(outdated.count)개 배럭을 v\(version)로 맞춰야 합니다", actionLabel: "모두 Sync",
                               barrackID: nil, sessionID: nil))
    }

    nonisolated static func staleSessions(_ barracks: [Barrack], now: Date) -> [(Barrack, HealthRules.ActiveSession, Int)] {
        barracks.flatMap { barrack -> [(Barrack, HealthRules.ActiveSession, Int)] in
            guard let index = try? String(contentsOfFile: barrack.path + "/SESSIONS.md", encoding: .utf8) else { return [] }
            return HealthRules.activeSessions(fromSessionsIndex: index).compactMap { session in
                let file = barrack.path + "/sessions/\(session.id).md"
                guard let modified = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date,
                      HealthRules.isStale(modified: modified, now: now) else { return nil }
                return (barrack, session, Int(now.timeIntervalSince(modified) / 3600))
            }
        }
    }

    nonisolated static func outdated(_ barracks: [Barrack], cliVersion: String) -> [Barrack] {
        barracks.filter { barrack in
            guard let yaml = try? String(contentsOfFile: barrack.path + "/agent.yaml", encoding: .utf8),
                  let line = yaml.split(separator: "\n").first(where: { $0.hasPrefix("aib_version:") }) else { return false }
            let version = line.dropFirst("aib_version:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return version != cliVersion
        }
    }
}
