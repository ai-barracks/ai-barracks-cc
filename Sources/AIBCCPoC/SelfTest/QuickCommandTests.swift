import Foundation

/// Quick Commands as in v1 (Codex parity audit P03): a run opens a new
/// terminal in the saved folder and types nothing into the focused one;
/// a missing folder asks; typing into a terminal refuses agents and asks
/// unless it is an idle shell; Save fills name, command and folder.
@MainActor
struct QuickCommandTests {
    let harness: SelfTestHarness

    func run() async -> [TestResult] {
        [await newTerminalInFolder(), await guardedTyping(), storage()]
    }

    /// QC-01a: run → new terminal whose shell is in the saved folder.
    private func newTerminalInFolder() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        var failures: [String] = []
        guard let focused = harness.makeRecorderPane(name: "qc-focus"), let barrack = workspace.selectedBarrack else {
            return .make("QC-01a", "Quick Command 새 터미널", status: .fail, cause: .app, evidence: ["reason": "setup"], startedAt: start)
        }
        workspace.editInProgress = false
        await harness.install([focused.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { focused.log.isReady }
        let folder = Self.makeFolder("qc-cwd")
        let marker = Self.tempFile("qc-pwd")
        defer { [folder, marker].forEach { try? FileManager.default.removeItem(atPath: $0) } }
        let mark = focused.log.mark()
        let quick = QuickCommand(label: "qc-run", command: "pwd -P > \(marker)", cwd: folder)
        let pane = workspace.run(quick)
        let wrote = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { Self.read(marker) != nil }
        if pane == nil || workspace.panes.count != 2 { failures.append("no new terminal (\(workspace.panes.count))") }
        if !wrote || Self.read(marker) != Self.real(folder) { failures.append("pwd \(Self.read(marker) ?? "none") ≠ \(Self.real(folder))") }
        await harness.pause(AppConstants.SelfTest.changeGrace)
        if !focused.log.bytes(since: mark).isEmpty { failures.append("typed into the focused terminal") }
        if let pane, pane.userCommand != quick.command || pane.workingDirectory != folder { failures.append("launch info not kept") }
        if let pane {
            workspace.saveDraft(from: pane)
            let draft = workspace.quickCommandDraft
            if draft?.command != quick.command || draft?.cwd != folder || draft?.label != "qc-run" { failures.append("save draft \(String(describing: draft))") }
            workspace.quickCommandDraft = nil
        }
        // A saved folder that is gone is never replaced silently.
        let count = workspace.panes.count
        let gone = QuickCommand(label: "qc-gone", command: "true", cwd: folder + "-gone")
        if workspace.run(gone) != nil || workspace.panes.count != count { failures.append("ran with a missing folder") }
        if case .missingFolder? = workspace.quickCommandPrompt {} else { failures.append("no missing-folder prompt") }
        workspace.quickCommandPrompt = nil
        // "배럭 폴더에서 이번만 실행".
        let marker2 = Self.tempFile("qc-pwd2")
        defer { try? FileManager.default.removeItem(atPath: marker2) }
        _ = workspace.runInBarrackFolder(QuickCommand(label: "qc-barrack", command: "pwd -P > \(marker2)", cwd: folder + "-gone"))
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { Self.read(marker2) != nil }
        if Self.read(marker2) != Self.real(barrack.path) { failures.append("barrack folder run \(Self.read(marker2) ?? "none")") }
        return .make("QC-01a", "Quick Command 실행 = 저장 폴더의 새 터미널(포커스 터미널 입력 0), 폴더 없음은 확인, 저장은 이름·명령·폴더",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// QC-01b: typing into a terminal refuses agents, asks for unknown
    /// programs, and goes straight into an idle shell.
    private func guardedTyping() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        var failures: [String] = []
        guard let agent = harness.makeRecorderPane(name: "qc-agent", agent: .claude),
              let program = harness.makeRecorderPane(name: "qc-program") else {
            return .make("QC-01b", "Quick Command 입력 보호", status: .fail, cause: .app, evidence: ["reason": "setup"], startedAt: start)
        }
        let shell = workspace.makePane(title: "qc-shell")
        await harness.install([agent.pane, program.pane, shell], layout: .quad)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { agent.log.isReady && program.log.isReady }
        let quick = QuickCommand(label: "qc-send", command: "qcsend")
        let agentMark = agent.log.mark()
        if workspace.send(quick, to: agent.pane) != .refused { failures.append("agent not refused") }
        let programMark = program.log.mark()
        if workspace.send(quick, to: program.pane) != .needsConfirmation { failures.append("unknown program not asked") }
        if case .confirmSend? = workspace.quickCommandPrompt {} else { failures.append("no confirm prompt") }
        workspace.quickCommandPrompt = nil
        await harness.pause(AppConstants.SelfTest.changeGrace)
        if !agent.log.bytes(since: agentMark).isEmpty { failures.append("typed into the agent") }
        if !program.log.bytes(since: programMark).isEmpty { failures.append("typed before confirm") }
        // An idle shell takes it without a question (daemon backend only).
        var idleChecked = "no daemon"
        if workspace.daemon != nil {
            let marker = Self.tempFile("qc-idle")
            defer { try? FileManager.default.removeItem(atPath: marker) }
            let idle = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { shell.isIdleShell }
            let outcome = workspace.send(QuickCommand(label: "qc-idle", command: "echo ok > \(marker)"), to: shell)
            let wrote = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { Self.read(marker) == "ok" }
            if !idle || outcome != .sent || !wrote { failures.append("idle shell idle=\(idle) outcome=\(outcome) wrote=\(wrote)") }
            idleChecked = "yes"
        }
        return .make("QC-01b", "터미널에 입력: 에이전트는 거부(0바이트), 모르는 프로그램은 확인 전 0바이트, 빈 셸은 바로 입력",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | "), "idle_shell_checked": idleChecked], startedAt: start)
    }

    /// QC-01c: records saved before folders existed still load; editing
    /// replaces in place; a blank folder means the barrack's.
    private func storage() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let old = #"[{"id":"7C2D6D2A-3C1B-4C5E-9D0A-1F2E3D4C5B6A","label":"a","command":"ls"}]"#
        let decoded = try? JSONDecoder().decode([QuickCommand].self, from: Data(old.utf8))
        if decoded?.first?.cwd != nil || decoded?.first?.command != "ls" { failures.append("old record") }
        let suite = "aibcc-qc3-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuickCommandStore(defaults: defaults)
        store.add(label: "x", command: "make", cwd: "  ")
        guard var first = store.commands.first else {
            return .make("QC-01c", "Quick Command 저장", status: .fail, cause: .app, evidence: ["failures": "not added"], startedAt: start)
        }
        if first.cwd != nil { failures.append("blank folder kept") }
        first.cwd = "/tmp"
        first.label = "y"
        store.upsert(first)
        let reloaded = QuickCommandStore(defaults: defaults).commands
        if reloaded.count != 1 || reloaded.first?.cwd != "/tmp" || reloaded.first?.label != "y" { failures.append("edit \(reloaded)") }
        let found = V1SettingsImport.parse(["cc-quick-commands": #"[{"label":"b","command":"npm test","cwd":"/tmp/p"},{"command":"ls","cwd":""}]"#])
        if found.quickCommands.map(\.cwd) != ["/tmp/p", nil] { failures.append("v1 import cwd \(found.quickCommands.map(\.cwd))") }
        return .make("QC-01c", "Quick Command 저장: 옛 기록(폴더 없음) 읽기, 편집은 제자리, 빈 폴더 = 배럭, v1 가져오기에 cwd",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    private static func makeFolder(_ name: String) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private static func tempFile(_ name: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-\(name)-\(UUID().uuidString)").path
    }

    private static func read(_ path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// `pwd -P` keeps /private; URL.resolvingSymlinksInPath drops it.
    private static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
