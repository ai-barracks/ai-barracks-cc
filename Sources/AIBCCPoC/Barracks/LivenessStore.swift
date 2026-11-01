import Foundation
import Observation

/// Liveness of every barrack, refreshed on a short interval. Read-only:
/// acknowledging a `done` belongs to M3.
@MainActor
@Observable
final class LivenessStore {
    private(set) var sessions: [Barrack.ID: [LiveSession]] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let barracks: [Barrack]

    init(barracks: [Barrack]) {
        self.barracks = barracks
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: AppConstants.Liveness.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let snapshot = barracks.reduce(into: [Barrack.ID: [LiveSession]]()) { result, barrack in
            result[barrack.id] = LivenessReader.read(barrackPath: barrack.path)
        }
        if snapshot != sessions { sessions = snapshot }
    }

    func sessions(of barrack: Barrack.ID) -> [LiveSession] { sessions[barrack] ?? [] }

    /// The state a barrack row shows: current attention first, then running.
    func headline(of barrack: Barrack.ID) -> Liveness {
        let all = sessions(of: barrack)
        let urgent = all.filter(\.needsAttention).map(\.state)
        for candidate: Liveness in [.blocked, .crashed, .done] where urgent.contains(candidate) { return candidate }
        let states = all.map(\.state)
        for candidate: Liveness in [.working, .workingStale] where states.contains(candidate) { return candidate }
        return .idle
    }

    var attentionCount: Int { sessions.values.flatMap { $0 }.filter(\.needsAttention).count }
    var runningCount: Int { sessions.values.flatMap { $0 }.filter { $0.state.isRunning }.count }
}
