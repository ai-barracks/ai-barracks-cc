import Darwin
import Foundation
import PtyProtocol

/// Codex r4 checks that need a daemon (run in persist2):
///   PS-04a  the attach replay's query is not answered again, a live query
///           right behind it is (exact boundary)
///   PS-04b  an ended program is archived only once its last output is on
///           screen, not when its PID exits
///   PS-02c  a daemon killed outright (no SHUTDOWN, the child still running)
///           still ends the pane — the connection loss alone tells it
extension PersistSuite {
    func replayFence() async -> TestResult {
        let start = ContinuousClock.now
        guard let daemon = harness.workspace.daemon, let recorder = harness.recorderCommand(name: "fence") else {
            return .make("PS-04a", "replay 경계", status: .fail, cause: .app,
                         evidence: ["reason": "no daemon or fixtures"], startedAt: start)
        }
        let id = UUID()
        let request = DaemonLaunch.request(command: recorder.command, workingDirectory: nil,
                                           environment: ["AIBCC_DA_QUERY": "1", "AIBCC_DA_ON_CTRL_A": "1"])
        // A throwaway connection creates it: nobody answers the start-up
        // query, so that query lives only in the replay.
        let created = FrameRequest.send(Frame(.create, session: id, payload: PtyProtocol.json(request)),
                                        to: daemon.socketPath, expecting: .created) != nil
        let ready = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorder.log.isReady }
        await harness.pause(AppConstants.SelfTest.changeGrace)
        // Attached before it has a surface: the replay waits unparsed.
        let pane = TerminalPane(controller: harness.workspace.controller, title: "fence", workingDirectory: nil,
                                backend: .daemon(daemon, sessionID: id, attach: true))
        let pending = { pane.remote?.terminal.pendingOutputByteCount ?? 0 }
        let replayQueued = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { pending() > 0 }
        let replayBytes = pending()
        // The live query: Ctrl+A from another connection; its output queues
        // right behind the replay.
        let mark = recorder.log.mark()
        _ = FrameRequest.send(Frame(.input, session: id, payload: Data([0x01])), to: daemon.socketPath)
        let triggered = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            recorder.log.bytes(since: mark).contains(0x01)
        }
        let liveQueued = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { pending() > replayBytes }
        let answers = recorder.log.mark()
        await harness.install([pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            Self.deviceAttributesReplies(recorder.log.bytes(since: answers)) > 0
        }
        await harness.pause(AppConstants.SelfTest.changeGrace)
        let replies = Self.deviceAttributesReplies(recorder.log.bytes(since: answers))
        let setUp = created && ready && replayQueued && triggered && liveQueued
        return .make("PS-04a", "재생된 질의는 응답 안 함, replay 바로 뒤 live 질의는 정확히 1회 응답",
                     status: setUp && replies == 1 ? .pass : .fail, cause: .app,
                     evidence: ["created": "\(created)", "ready": "\(ready)", "replay_queued_bytes": "\(replayBytes)",
                                "live_queued": "\(liveQueued)", "triggered": "\(triggered)",
                                "da_replies": "\(replies)",
                                "input": Hex.string(recorder.log.bytes(since: answers))],
                     startedAt: start)
    }

    func archiveAfterOutput() async -> TestResult {
        let start = ContinuousClock.now
        let marker = "ARCHIVE-END-\(UUID().uuidString.prefix(8))"
        // Megabytes of output, the marker last, then exit at once: the PID
        // is gone well before the terminal has parsed it all.
        let pane = harness.workspace.makePane(
            title: "archive-tail", command: "head -c 4000000 /dev/zero | tr '\\0' x; echo; echo \(marker)"
        )
        await harness.install([pane], layout: .single)
        let id = pane.id.uuidString
        let archived = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) {
            harness.workspace.scrollback.record(id) != nil
        }
        let text = harness.workspace.scrollback.text(of: id) ?? ""
        return .make("PS-04b", "종료한 프로그램의 마지막 출력까지 보관(PID 종료 시점 아님)",
                     status: archived && text.contains(marker) ? .pass : .fail, cause: .app,
                     evidence: ["archived": "\(archived)", "marker": marker, "has_marker": "\(text.contains(marker))",
                                "tail": String(text.suffix(80))],
                     startedAt: start)
    }

    /// Runs after PS-02b, with the restarted daemon.
    func daemonKilled() async -> TestResult {
        let start = ContinuousClock.now
        guard let daemon = harness.workspace.daemon, daemon.ensureRunning(),
              let daemonPID = Self.peerPID(of: daemon.socketPath), Self.processName(daemonPID) == AppConstants.Daemon.executableName
        else {
            return .make("PS-02c", "데몬 강제 종료 감지", status: .fail, cause: .app,
                         evidence: ["reason": "daemon pid not found"], startedAt: start)
        }
        let readyFile = FileManager.default.temporaryDirectory.appendingPathComponent("ps02c-\(UUID().uuidString).ready")
        // Ignores the hang-up, so the child outlives the daemon: only the
        // lost connection can end the pane.
        let pane = harness.workspace.makePane(
            title: "outlives-daemon", command: "trap '' HUP; : > '\(readyFile.path)'; while :; do sleep 1; done"
        )
        await harness.install([pane], layout: .single)
        let ready = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) {
            FileManager.default.fileExists(atPath: readyFile.path) && pane.processID != nil
        }
        let child = pane.processID ?? 0
        Darwin.kill(daemonPID, SIGKILL)
        let ended = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { pane.hasExited }
        let childAlive = child > 0 && Darwin.kill(child, 0) == 0
        if child > 0 { Darwin.kill(-child, SIGKILL) }
        try? FileManager.default.removeItem(at: readyFile)
        let next = harness.makeRecorderPane(name: "post-kill")
        if let next { await harness.install([next.pane], layout: .single) }
        let recovered = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { next?.log.isReady == true }
        return .make("PS-02c", "데몬 SIGKILL(자식 생존) → pane 종료 표시, 새 pane은 새 데몬으로 시작",
                     status: ready && ended && childAlive && recovered ? .pass : .fail, cause: .app,
                     evidence: ["daemon_pid": "\(daemonPID)", "ready": "\(ready)", "pane_ended": "\(ended)",
                                "child_alive_at_end": "\(childAlive)", "new_pane_ready": "\(recovered)"],
                     startedAt: start)
    }

    static func deviceAttributesReplies(_ bytes: [UInt8]) -> Int {
        guard bytes.count >= 3 else { return 0 }
        return (0 ..< bytes.count - 2).filter { bytes[$0] == 0x1b && bytes[$0 + 1] == 0x5b && bytes[$0 + 2] == 0x3f }.count
    }

    /// The process serving a Unix socket (LOCAL_PEERPID).
    static func peerPID(of socketPath: String) -> pid_t? {
        guard let fd = UnixSocket.connect(path: socketPath) else { return nil }
        defer { close(fd) }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    static func processName(_ pid: pid_t) -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : ""
    }
}
