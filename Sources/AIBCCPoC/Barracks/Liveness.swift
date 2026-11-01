import Darwin
import Foundation

/// aib agent liveness (sessions/.live/<id>.status + optional .ack), folded
/// exactly like `aib sessions state` / CC v1.6.1 `live::fold`.
enum Liveness: String, Sendable, CaseIterable {
    case working, workingStale = "working_stale", blocked, crashed, interrupted, done, idle, none

    /// Attention ring: something needs the user (spec §3).
    var needsAttention: Bool { self == .blocked || self == .done || self == .crashed }
    var isRunning: Bool { self == .working || self == .workingStale }

    var label: String {
        switch self {
        case .working: "작업 중"
        case .workingStale: "응답 없음"
        case .blocked: "입력 대기"
        case .crashed: "비정상 종료"
        case .interrupted: "중단됨"
        case .done: "완료"
        case .idle: "대기"
        case .none: "알 수 없음"
        }
    }

    enum PidState: Sendable { case alive, dead, unknown }

    /// Pure fold — must match aib's reference (fold matrix in CC live.rs).
    static func fold(state: String, statusTimestamp: Int, runID: String, ack: Ack?,
                     now: Int, pid: PidState, staleAfter: Int) -> Liveness {
        let acked = ack.map { $0.runID == runID && $0.timestamp >= statusTimestamp } ?? false
        switch state {
        case "done": return acked ? .idle : .done
        case "blocked": return pid == .dead ? .crashed : .blocked
        case "working":
            if pid == .dead { return .interrupted }
            return now - statusTimestamp > staleAfter ? .workingStale : .working
        default: return .none
        }
    }

    struct Ack: Sendable, Equatable {
        let runID: String
        let timestamp: Int
    }
}

/// One session's folded state, with the evidence a tooltip should show.
struct LiveSession: Identifiable, Sendable, Equatable {
    let id: String
    let state: Liveness
    let ageSeconds: Int
    let pid: Int32
    let cwd: String?

    /// The ring is for what needs you now. A `blocked` process is waiting
    /// for as long as it lives; a `done` or `crashed` nobody looked at for
    /// half a day is history (the maintenance queue offers gc), not an
    /// alarm — on 2026-11-01 five barracks rang for finishes 1 h–152 days old.
    var needsAttention: Bool {
        state == .blocked || (state.needsAttention && ageSeconds <= AppConstants.Liveness.attentionWindow)
    }
}

enum LivenessReader {
    /// AIB_LIVE_STALE_WORKING, default 180 s — the same knob aib reads.
    static var staleAfter: Int {
        ProcessInfo.processInfo.environment["AIB_LIVE_STALE_WORKING"].flatMap(Int.init) ?? 180
    }

    static func read(barrackPath: String, now: Int = Int(Date().timeIntervalSince1970)) -> [LiveSession] {
        let directory = URL(fileURLWithPath: barrackPath).appendingPathComponent("sessions/.live")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "status" }.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["session_id"] as? String, let state = json["state"] as? String,
                  let timestamp = json["ts"] as? Int
            else { return nil }
            let pid = Int32(json["pid"] as? Int ?? 0)
            let folded = Liveness.fold(
                state: state, statusTimestamp: timestamp, runID: json["run_id"] as? String ?? "",
                ack: ack(for: file), now: now, pid: pidState(pid), staleAfter: staleAfter
            )
            return LiveSession(id: id, state: folded, ageSeconds: max(now - timestamp, 0), pid: pid,
                               cwd: json["cwd"] as? String)
        }
        .sorted { $0.ageSeconds < $1.ageSeconds }
    }

    private static func ack(for statusFile: URL) -> Liveness.Ack? {
        guard let data = try? Data(contentsOf: statusFile.deletingPathExtension().appendingPathExtension("ack")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runID = json["acked_run_id"] as? String, let timestamp = json["ack_ts"] as? Int
        else { return nil }
        return Liveness.Ack(runID: runID, timestamp: timestamp)
    }

    private static func pidState(_ pid: Int32) -> Liveness.PidState {
        guard pid > 0 else { return .unknown }
        if kill(pid, 0) == 0 { return .alive }
        return errno == ESRCH ? .dead : .unknown
    }
}
