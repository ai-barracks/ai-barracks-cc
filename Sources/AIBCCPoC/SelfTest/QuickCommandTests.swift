import Foundation

/// Quick Commands as in v1 (Codex parity audit P03, and its review): a run
/// opens a new terminal in the saved folder and types nothing into the
/// focused one; the folder is checked after an open edit is left; typing
/// into an existing terminal always asks and is re-checked when it would
/// type; Save fills name, command and folder, which survive a relaunch.
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
            return Self.fail("QC-01a", "setup", start)
        }
        workspace.editInProgress = false
        let installed = await harness.install([focused.pane], layout: .single)
        guard installed, await harness.waitUntil(AppConstants.SelfTest.readyTimeout, { focused.log.isReady }) else {
            return Self.fail("QC-01a", "focused recorder not ready", start)
        }
        let folder = Self.makeFolder("qc-cwd")
        let marker = Self.tempFile("qc-pwd")
        let quoted = Self.tempFile("qc-quoted")
        let heredoc = Self.tempFile("qc-heredoc")
        defer { [folder, marker, quoted, heredoc].forEach { try? FileManager.default.removeItem(atPath: $0) } }
        let mark = focused.log.mark()
        // A trailing ";", quotes and a here-document must survive the wrapper.
        let quick = QuickCommand(label: "qc-run", command: "pwd -P > \(marker); printf '%s' 'a \"b\";' > \(quoted);\ncat > \(heredoc) <<'QC'\nhere\nQC", cwd: folder)
        let pane = workspace.run(quick)
        let wrote = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { Self.read(heredoc) != nil }
        if pane == nil || workspace.panes.count != 2 { failures.append("no new terminal (\(workspace.panes.count))") }
        if Self.read(marker) != Self.real(folder) { failures.append("pwd \(Self.read(marker) ?? "none") ≠ \(Self.real(folder))") }
        if !wrote || Self.read(quoted) != "a \"b\";" || Self.read(heredoc) != "here" {
            failures.append("shell syntax quoted=\(Self.read(quoted) ?? "none") heredoc=\(Self.read(heredoc) ?? "none")")
        }
        await harness.pause(AppConstants.SelfTest.changeGrace)
        if !focused.log.bytes(since: mark).isEmpty { failures.append("typed into the focused terminal") }
        if let pane {
            if pane.userCommand != quick.command || pane.workingDirectory != folder { failures.append("launch info not kept") }
            failures += savedLaunch(of: pane, command: quick.command, folder: folder)
            workspace.saveDraft(from: pane)
            let draft = workspace.quickCommandDraft
            if draft?.command != quick.command || draft?.cwd != folder || draft?.label != "qc-run" { failures.append("save draft") }
            workspace.quickCommandDraft = nil
        }
        failures += await missingFolder(folder: folder, barrack: barrack.path)
        return .make("QC-01a", "Quick Command 실행 = 저장 폴더의 새 터미널(포커스 터미널 입력 0, ; 따옴표 here-doc 유지), 폴더는 편집 이동 뒤 재확인, 시작 정보 저장",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// The daemon's session record keeps how the pane started.
    private func savedLaunch(of pane: TerminalPane, command: String, folder: String) -> [String] {
        guard let daemon = harness.workspace.daemon, let session = pane.remote?.id else { return [] }
        let saved = SessionStore.load(from: daemon.sessionStoreURL)?.grids.values.flatMap(\.panes).first { $0.session == session }
        return saved?.command == command && saved?.directory == folder ? [] : ["launch not saved \(String(describing: saved))"]
    }

    private func missingFolder(folder: String, barrack: String) async -> [String] {
        let workspace = harness.workspace
        var failures: [String] = []
        // A folder that vanishes while "leave the edit?" is open is caught
        // when the terminal would be made, not only when asked.
        let count = workspace.panes.count
        let doomed = Self.makeFolder("qc-doomed")
        workspace.editInProgress = true
        if workspace.run(QuickCommand(label: "qc-doomed", command: "true", cwd: doomed)) != nil { failures.append("ran during an edit") }
        try? FileManager.default.removeItem(atPath: doomed)
        workspace.confirmNavigation()
        await harness.settleSheet(shown: true)
        if workspace.panes.count != count { failures.append("ran in a vanished folder") }
        if case .missingFolder? = workspace.quickCommandPrompt {} else { failures.append("no missing-folder prompt after the edit") }
        workspace.quickCommandPrompt = nil
        await harness.settleSheet(shown: false)
        // "배럭 폴더에서 이번만 실행".
        let marker = Self.tempFile("qc-pwd2")
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let gone = QuickCommand(label: "qc-barrack", command: "pwd -P > \(marker)", cwd: folder + "-gone")
        _ = workspace.runInBarrackFolder(gone)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { Self.read(marker) != nil }
        if Self.read(marker) != Self.real(barrack) { failures.append("barrack folder run \(Self.read(marker) ?? "none")") }
        // "경로 수정" opens the editor once the alert has closed.
        workspace.editAfterAlert(gone)
        let editing = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { workspace.quickCommandDraft?.id == gone.id }
        if !editing { failures.append("path fix did not open the editor") }
        await harness.settleSheet(shown: true)
        workspace.quickCommandDraft = nil
        await harness.settleSheet(shown: false)
        return failures
    }

    /// QC-01b: typing into a terminal always asks; agents, a program that
    /// changed after the yes, and an agent that started during "leave the
    /// edit?" are refused with 0 bytes; the plain yes types (positive control).
    private func guardedTyping() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        var failures: [String] = []
        guard let agent = harness.makeRecorderPane(name: "qc-agent", agent: .claude),
              let program = harness.makeRecorderPane(name: "qc-program") else { return Self.fail("QC-01b", "setup", start) }
        let shell = workspace.makePane(title: "qc-shell")
        workspace.editInProgress = false
        let installed = await harness.install([agent.pane, program.pane, shell], layout: .quad)
        guard installed, await harness.waitUntil(AppConstants.SelfTest.readyTimeout, { agent.log.isReady && program.log.isReady }) else {
            return Self.fail("QC-01b", "recorders not ready", start)
        }
        let quick = QuickCommand(label: "qc-send", command: "qcsend")
        let agentMark = agent.log.mark()
        if workspace.send(quick, to: agent.pane) != .refused { failures.append("agent not refused") }
        // Even an idle shell is asked about: "no child" is not "at a prompt".
        if workspace.send(quick, to: shell) != .needsConfirmation { failures.append("shell typed without asking") }
        workspace.quickCommandPrompt = nil
        let mark = program.log.mark()
        guard workspace.send(quick, to: program.pane) == .needsConfirmation,
              case let .confirmSend(_, _, seen)? = workspace.quickCommandPrompt else {
            return Self.fail("QC-01b", "no confirm prompt", start)
        }
        workspace.quickCommandPrompt = nil
        // The program changed after the yes.
        if workspace.confirmSend(quick, to: program.pane, program: ForegroundProgram(group: 1, name: "launchd")) != .refused {
            failures.append("changed program not refused")
        }
        // An agent started while "leave the edit?" was open.
        workspace.editInProgress = true
        if workspace.confirmSend(quick, to: program.pane, program: seen) != .needsConfirmation { failures.append("typed during an edit") }
        program.pane.agent = .codex
        workspace.confirmNavigation()
        await harness.pause(AppConstants.SelfTest.changeGrace)
        program.pane.agent = nil
        if !agent.log.bytes(since: agentMark).isEmpty || !program.log.bytes(since: mark).isEmpty { failures.append("typed after a refusal") }
        // Positive control: the plain yes reaches the recorder.
        let outcome = workspace.confirmSend(quick, to: program.pane, program: seen)
        let typed = await harness.settledBytes(program.log, since: mark, expectingAtLeast: 6)
        if outcome != .sent || !String(decoding: typed, as: UTF8.self).contains("qcsend") { failures.append("confirmed send missing (\(outcome))") }
        return .make("QC-01b", "터미널에 입력은 항상 확인: 에이전트·확인 뒤 바뀐 프로그램·편집 이동 중 에이전트 시작은 0바이트, 확인하면 입력",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | "), "seen": seen?.name ?? "unknown"], startedAt: start)
    }

    /// QC-01c: records saved before folders existed still load; editing
    /// replaces in place; a blank folder means the barrack's while a real
    /// one is kept as given; a v1 import fills the folder an earlier import
    /// missed and keeps different folders apart; old session records load.
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
        store.add(label: "y", command: "make", cwd: "/tmp/project ")
        if store.commands.map(\.cwd) != [nil, "/tmp/project "] { failures.append("folder text \(store.commands.map(\.cwd))") }
        if var first = store.commands.first {
            first.label = "x2"
            store.upsert(first)
        }
        if QuickCommandStore(defaults: defaults).commands.map(\.label) != ["x2", "y"] { failures.append("edit in place") }
        // An earlier import brought "b / npm test" without its folder.
        store.add(label: "b", command: "npm test")
        let found = V1SettingsImport.parse(["cc-quick-commands": #"[{"label":"b","command":"npm test","cwd":"/tmp/p"},{"label":"c","command":"npm test","cwd":"/tmp/q"},{"command":"ls","cwd":""}]"#])
        if found.quickCommands.map(\.cwd) != ["/tmp/p", "/tmp/q", nil] { failures.append("v1 parse cwd \(found.quickCommands.map(\.cwd))") }
        _ = V1SettingsImport.apply(found, quickCommands: store, defaults: defaults)
        let merged = QuickCommandStore(defaults: defaults).commands.filter { $0.command == "npm test" }.map { "\($0.label)@\($0.cwd ?? "-")" }
        if merged.sorted() != ["b@/tmp/p", "c@/tmp/q"] { failures.append("v1 merge \(merged)") }
        let session = #"{"selectedBarrackID":null,"grids":{"x":{"layout":1,"splitX":0.5,"splitY":0.5,"panes":[{"session":"7C2D6D2A-3C1B-4C5E-9D0A-1F2E3D4C5B6A","title":"t"}]}}}"#
        let pane = (try? JSONDecoder().decode(SavedWorkspace.self, from: Data(session.utf8)))?.grids["x"]?.panes.first
        if pane == nil || pane?.directory != nil || pane?.command != nil { failures.append("old session record") }
        return .make("QC-01c", "Quick Command 저장: 옛 기록 읽기, 편집은 제자리, 빈 폴더 = 배럭·실제 경로는 그대로, v1 가져오기가 빠진 폴더 보완·다른 폴더 구분, 옛 세션 기록",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    private static func fail(_ id: String, _ reason: String, _ start: ContinuousClock.Instant) -> TestResult {
        .make(id, "Quick Command", status: .fail, cause: .app, evidence: ["reason": reason], startedAt: start)
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
        let text = (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    /// `pwd -P` keeps /private; URL.resolvingSymlinksInPath drops it.
    private static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
