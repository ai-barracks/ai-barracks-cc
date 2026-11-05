import AppKit
import Foundation
import PtyProtocol

/// PS-01: a daemon-owned session survives an app quit and the next launch
/// reattaches to it. Two app launches driven by scripts/run-persist-test.sh:
///   persist1 — create a recorder session, type, record its identity, quit
///   persist2 — the relaunched app restored the grid by itself; check the
///              same process, the replayed screen, no stray input, live input
@MainActor
struct PersistSuite {
    let harness: SelfTestHarness

    /// Handoff between the two launches.
    struct State: Codable {
        let session: UUID
        let pid: Int32
        let banner: String
        let logPath: String
        let logMark: Int
    }

    private var stateURL: URL {
        harness.outputDirectory.deletingLastPathComponent().appendingPathComponent("persist-state.json")
    }

    func phaseOne() async -> [TestResult] {
        let start = ContinuousClock.now
        let banner = "PERSIST-\(UUID().uuidString.prefix(8))"
        guard harness.workspace.daemon != nil, let window = harness.window,
              let recorder = harness.makeRecorderPane(
                  name: "persist", environment: ["AIBCC_BANNER": banner, "AIBCC_DA_QUERY": "1"]
              ),
              let session = recorder.pane.remote
        else {
            return [.make("PS-01-setup", "1단계 준비", status: .fail, cause: .app,
                          evidence: ["reason": "needs --backend=daemon and a reachable daemon"], startedAt: start)]
        }
        await harness.install([recorder.pane], layout: .single)
        let ready = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorder.log.isReady }
        let rendered = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) {
            session.terminal.readViewportText()?.contains(banner) == true
        }
        // The answer to the fixture's DA1 query proves the terminal answers
        // queries; phase 2 then shows the replayed one is not answered again.
        let answered = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            Self.containsDeviceAttributesReply(recorder.log.bytes(since: 0))
        }
        harness.focus(recorder.pane)
        let mark = recorder.log.mark()
        EventSynthesizer.type("p1", in: window)
        let typed = await harness.settledBytes(recorder.log, since: mark, expectingAtLeast: 2)
        let pid = recorder.pane.processID ?? 0
        let state = State(session: session.id, pid: pid, banner: banner,
                          logPath: recorder.log.url.path, logMark: recorder.log.mark())
        let saved = (try? JSONEncoder().encode(state)).map { (try? $0.write(to: stateURL, options: .atomic)) != nil } ?? false
        let ok = ready && rendered && answered && typed == Hex.bytes("p1") && pid > 0 && saved
        return [.make("PS-01-setup", "1단계: 데몬 세션 생성·렌더·DA 응답·입력·상태 기록",
                      status: ok ? .pass : .fail, cause: .app,
                      evidence: ["session": session.id.uuidString, "pid": "\(pid)", "ready": "\(ready)",
                                 "rendered": "\(rendered)", "da_answered": "\(answered)",
                                 "typed": Hex.string(typed), "state_saved": "\(saved)"],
                      startedAt: start)]
    }

    func phaseTwo() async -> [TestResult] {
        let start = ContinuousClock.now
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data),
              harness.workspace.daemon != nil, let window = harness.window
        else {
            return [.make("PS-01-setup", "2단계 준비", status: .fail, cause: .app,
                          evidence: ["reason": "no phase-1 state or no daemon backend"], startedAt: start)]
        }
        let log = RecorderLog(url: URL(fileURLWithPath: state.logPath))
        let restored = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) {
            restoredPane(state)?.processID != nil && restoredPane(state)?.probeView?.window != nil
        }
        guard restored, let pane = restoredPane(state), let session = pane.remote else {
            return [.make("PS-01a", "재실행 후 같은 세션 자동 재부착", status: .fail, cause: .app,
                          evidence: ["reason": "restored grid has no pane for \(state.session)"], startedAt: start)]
        }
        let samePID = pane.processID == state.pid
        let alive = ProcessCWD.isAlive(state.pid) && !pane.hasExited
        let replayed = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) {
            session.terminal.readViewportText()?.contains(state.banner) == true
        }
        await harness.pause(AppConstants.SelfTest.changeGrace)
        let stray = log.bytes(since: state.logMark)

        harness.focus(pane)
        let mark = log.mark()
        EventSynthesizer.type("p2", in: window)
        let typed = await harness.settledBytes(log, since: mark, expectingAtLeast: 2)
        let orphans = await orphanSessions()
        return [
            .make("PS-01a", "앱 종료 후 같은 프로세스가 살아 있고 재실행 시 자동 재부착",
                  status: samePID && alive ? .pass : .fail, cause: .app,
                  evidence: ["expected_pid": "\(state.pid)", "attached_pid": pane.processID.map(String.init) ?? "nil",
                             "alive": "\(alive)"], startedAt: start),
            .make("PS-01b", "이전 출력이 재부착 화면에 재생됨",
                  status: replayed ? .pass : .fail, cause: .app,
                  evidence: ["banner": state.banner,
                             "viewport_head": String((session.terminal.readViewportText() ?? "nil").prefix(120))],
                  startedAt: start),
            .make("PS-01c", "재부착 후 입력이 같은 프로세스에 도달",
                  status: typed == Hex.bytes("p2") ? .pass : .fail, cause: .app,
                  evidence: ["typed": Hex.string(typed)], startedAt: start),
            .make("PS-01d", "재생된 질의(DA1)에 대한 응답이 입력으로 새지 않음",
                  status: stray.isEmpty ? .pass : .fail, cause: .app,
                  evidence: ["stray_bytes": Hex.string(stray)], startedAt: start),
            .make("PS-01e", "어떤 pane도 가리키지 않는 살아 있는 데몬 세션 0 (교체된 pane 정리)",
                  status: orphans.map(\.isEmpty) == true ? .pass : .fail, cause: .app,
                  evidence: ["orphans": orphans.map { $0.map(\.uuidString).joined(separator: ",") } ?? "list failed",
                             "restore": harness.workspace.restoreSummary],
                  startedAt: start),
        ]
    }

    /// Alive daemon sessions that no pane in any grid refers to.
    private func orphanSessions() async -> [UUID]? {
        // Kills from the restore sweep take a moment to land.
        await harness.pause(AppConstants.SelfTest.changeGrace)
        guard let daemon = harness.workspace.daemon, let sessions = daemon.listSessions() else { return nil }
        let referenced = Set(harness.workspace.grids.values.flatMap(\.panes).compactMap { $0.remote?.id })
        return sessions.filter { $0.alive && !referenced.contains($0.id) }.map(\.id)
    }

    /// PS-02 (self-review fixes): a failed attach ends visibly instead of
    /// leaving a blank muted pane; after the daemon stops (SHUTDOWN) or is
    /// killed, existing panes show as ended and a new pane starts a new
    /// daemon. Runs last in persist2: it stops the daemon.
    func recovery() async -> [TestResult] {
        let start = ContinuousClock.now
        guard let daemon = harness.workspace.daemon else { return [] }
        let missing = TerminalPane(controller: harness.workspace.controller, title: "missing", workingDirectory: nil,
                                   backend: .daemon(daemon, sessionID: UUID(), attach: true))
        await harness.install([missing], layout: .single)
        let failedVisibly = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            missing.hasExited && missing.failure != nil
        }
        let attachFailure = TestResult.make(
            "PS-02a", "없는 세션 attach → 종료 배너(빈 화면·입력 차단 방치 없음)",
            status: failedVisibly ? .pass : .fail, cause: .app,
            evidence: ["failure": missing.failure ?? "nil", "exited": "\(missing.hasExited)"], startedAt: start)

        guard let before = harness.makeRecorderPane(name: "pre-crash") else { return [attachFailure] }
        await harness.install([before.pane], layout: .single)
        let beforeReady = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { before.log.isReady }
        _ = FrameRequest.send(Frame(.shutdown), to: daemon.socketPath)
        let endedWithDaemon = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { before.pane.hasExited }
        let daemonGone = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { daemon.listSessions() == nil }
        let after = harness.makeRecorderPane(name: "post-crash")
        if let after { await harness.install([after.pane], layout: .single) }
        let recovered = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { after?.log.isReady == true }
        // SHUTDOWN ends the children too, so this one cannot tell a broken
        // connection-loss path from a PID monitor: PS-02c can (Codex r4).
        let shutdown = TestResult.make(
            "PS-02b", "데몬 SHUTDOWN 시 기존 pane은 종료 표시, 새 pane은 데몬 재기동으로 정상 시작",
            status: beforeReady && endedWithDaemon && daemonGone && recovered ? .pass : .fail, cause: .app,
            evidence: ["before_ready": "\(beforeReady)", "existing_ended": "\(endedWithDaemon)",
                       "daemon_gone": "\(daemonGone)", "new_pane_ready": "\(recovered)"], startedAt: start)
        return [attachFailure, shutdown, await daemonKilled()]
    }

    private func restoredPane(_ state: State) -> TerminalPane? {
        harness.workspace.panes.first { $0.remote?.id == state.session }
    }

    /// DA1 answers look like ESC [ ? … c.
    static func containsDeviceAttributesReply(_ bytes: [UInt8]) -> Bool {
        guard let start = bytes.indices.first(where: { index in
            index + 2 < bytes.count && bytes[index] == 0x1b && bytes[index + 1] == 0x5b && bytes[index + 2] == 0x3f
        }) else { return false }
        return bytes[(start + 3)...].contains(0x63)
    }
}
