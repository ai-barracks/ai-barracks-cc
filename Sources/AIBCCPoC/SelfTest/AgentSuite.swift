import AppKit

/// M3 in the real window: ⌘N grows the preset and focuses the new pane;
/// ⌘⇧A finds the pane that runs an agent by process tree. Uses the
/// "터미널" client so no real agent starts.
@MainActor
struct AgentSuite {
    let harness: SelfTestHarness

    func run() async -> [TestResult] {
        [await launchGrowsAndFocuses(), await shortcutReachesMenu(), await matchesPaneByProcess(),
         await maintenanceRunsInPane(), await maintenanceScanCompletes(), await maintenanceFollowsBarrack(), await fullGridMakesRoom(), await singleAfterSplitUsesFullSize(), await agentListKeepsOrder(), await destinationRoundTrip(),
         await sealsAgreeWithAib(), await searchHitOpens(), await noticeActionLands(), await fileEventsRefresh(),
         await registryReload(), await terminalManagement(), await archiveOnClose(), await navigationGuard(), await modelEntryPointsAsk(), await nothingBeforeConfirm(), restoreFailureKeepsSessions(), agentsStartEmpty(),
         await settingsApply(), await lineHeightApplies(), await twoRowsLayout()] + (await QuickCommandTests(harness: harness).run())
    }

    private func launchGrowsAndFocuses() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        guard let first = harness.makeRecorderPane(name: "agent-base") else {
            return .make("AG-01b", "⌘N 시작", status: .fail, cause: .app, evidence: ["reason": "setup"], startedAt: start)
        }
        await harness.install([first.pane], layout: .single)
        let launched = workspace.launchAgent(.terminal, skipPermissions: false)
        let attached = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) {
            launched?.probeView?.window != nil && launched?.processID != nil
        }
        let focused = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { harness.isFirstResponder(launched?.probeView) }
        let ok = attached && focused && workspace.layout == .double && workspace.panes.count == 2
            && workspace.destination == .sessions
        return .make("AG-01b", "⌘N: 1분할 → 2분할로 늘려 새 pane 시작·포커스",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["layout": "\(workspace.layout)", "panes": "\(workspace.panes.count)",
                                "attached": "\(attached)", "focused": "\(focused)"], startedAt: start)
    }

    /// ⌘N typed in a focused terminal must open the sheet, not reach
    /// Ghostty's own keybind (cf. ⌥⌘I, IN-11b) nor the PTY.
    private func shortcutReachesMenu() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        guard let recorder = harness.makeRecorderPane(name: "agent-shortcut"), let window = harness.window,
              let key = EventSynthesizer.key("n", modifiers: .command)
        else { return .make("AG-01c", "⌘N", status: .fail, cause: .app, evidence: ["reason": "setup"], startedAt: start) }
        await harness.install([recorder.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorder.log.isReady }
        harness.focus(recorder.pane)
        let mark = recorder.log.mark()
        EventSynthesizer.press(key, in: window)
        let opened = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { workspace.isNewAgentSheetPresented }
        let leaked = await harness.settledBytes(recorder.log, since: mark, expectingAtLeast: 0)
        workspace.isNewAgentSheetPresented = false
        await harness.pause(.milliseconds(400))
        return .make("AG-01c", "터미널 포커스에서 ⌘N → 시작 시트(PTY로 새지 않음)",
                     status: opened && leaked.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["sheet": "\(opened)", "leaked": Hex.string(leaked)], startedAt: start)
    }

    /// A 정비 action runs visibly: a new pane, the command, a shell after.
    private func maintenanceRunsInPane() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-mt-\(UUID().uuidString)")
        guard let base = harness.makeRecorderPane(name: "mt-base") else {
            return .make("MT-01b", "정비 실행", status: .fail, cause: .app, evidence: ["reason": "setup"], startedAt: start)
        }
        await harness.install([base.pane], layout: .single)
        let pane = workspace.runInPane(title: "정비", command: "echo done > \(AgentLauncher.shellQuote(marker.path))")
        let ran = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) {
            FileManager.default.fileExists(atPath: marker.path)
        }
        try? FileManager.default.removeItem(at: marker)
        let ok = ran && pane != nil && workspace.panes.count == 2
        return .make("MT-01b", "정비 동작은 새 터미널 pane에서 실행(결과가 보임)",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["ran": "\(ran)", "panes": "\(workspace.panes.count)"], startedAt: start)
    }

    /// The read-only scan against the real aib finishes.
    private func maintenanceScanCompletes() async -> TestResult {
        let start = ContinuousClock.now
        let store = harness.workspace.maintenance
        let barrack = harness.workspace.selectedBarrack
        await store.scan(barrack)
        let elapsed = (ContinuousClock.now - start).milliseconds
        return .make("MT-01c", "정비 점검(aib dry-run·verify·lint)이 끝나고 항목을 냄",
                     status: !store.isScanning(barrack) && elapsed < 30_000 ? .pass : .fail, cause: .app,
                     evidence: ["items": store.items(for: barrack).map { "\($0.kind.rawValue)=\($0.count)" }.joined(separator: ","),
                                "ms": String(format: "%.0f", elapsed)], startedAt: start)
    }

    /// PN-01b (P01, 2026-11-12 report: a barrack could not run a fifth
    /// agent): with four busy terminals a fifth and sixth start and show,
    /// none is ended, and a held one comes back into the focused slot.
    private func fullGridMakesRoom() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        var failures: [String] = []
        workspace.editInProgress = false
        workspace.destination = .sessions
        let busy = (1 ... 4).map { workspace.makePane(title: "pn busy \($0)", command: "sleep 60") }
        await harness.install(busy, layout: .quad)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { busy.allSatisfy { $0.processID != nil } }
        let notices = workspace.notices.notices.filter { $0.kind == .panes }.count
        let fifth = workspace.runInPane(title: "pn-5", command: "sleep 60")
        let sixth = workspace.runInPane(title: "pn-6", command: "sleep 60")
        let visible = workspace.panes.prefix(workspace.layout.paneCount).map(\.id)
        if fifth == nil || sixth == nil || workspace.panes.count != 6 { failures.append("started \(workspace.panes.count) of 6") }
        if let sixth, !visible.contains(sixth.id) { failures.append("newest not on screen") }
        if workspace.layout != .quad { failures.append("layout \(workspace.layout)") }
        if workspace.notices.notices.filter({ $0.kind == .panes }).count != notices { failures.append("full-grid notice") }
        await harness.pause(.milliseconds(500))
        let ended = (busy + [fifth, sixth].compactMap { $0 }).filter { $0.hasExited }.map(\.title)
        if !ended.isEmpty { failures.append("ended \(ended)") }
        if let held = workspace.panes.dropFirst(workspace.layout.paneCount).first {
            workspace.selectPane(id: held.id)
            if !workspace.panes.prefix(workspace.layout.paneCount).contains(where: { $0.id == held.id }) {
                failures.append("held pane not brought up")
            }
            if workspace.panes.count != 6 { failures.append("bringing up changed count") }
        } else {
            failures.append("nothing held off screen")
        }
        return .make("PN-01b", "터미널 상한 없음: 4칸이 모두 바빠도 5·6번째가 시작돼 화면에 보이고, 어느 것도 끝나지 않으며, 화면 밖 터미널을 고르면 칸으로 옴",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | "),
                                "panes": workspace.panes.map(\.title).joined(separator: ",")], startedAt: start)
    }

    /// PN-03a (2026-11-13 report on beta.7: after a second agent split the
    /// view, going back to one terminal left it at the split's size): each
    /// terminal shown alone after a split has the size it had alone before.
    private func singleAfterSplitUsesFullSize() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        var steps: [String] = []
        var ok = true
        workspace.editInProgress = false
        workspace.destination = .sessions
        let sizes = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-pn3-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sizes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sizes) }
        // Each terminal keeps writing its PTY's size, so the test sees what
        // the program inside is told, not only what the view draws.
        let report = { (name: String) in
            "/bin/sh -c " + AgentLauncher.shellQuote("while :; do stty size > \(sizes.path)/\(name).tmp && mv \(sizes.path)/\(name).tmp \(sizes.path)/\(name); sleep 0.1; done")
        }
        let pty = { (name: String) in
            (try? String(contentsOf: sizes.appendingPathComponent(name), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let agrees = { (pane: TerminalPane, name: String) -> Bool in
            guard let size = pane.state.surfaceSize else { return false }
            return pty(name) == "\(size.rows) \(size.columns)"
        }
        let first = workspace.makePane(title: "pn3 a", command: report("a"))
        await harness.install([first], layout: .single)
        await harness.pause(.milliseconds(600))
        let alone = first.state.surfaceSize
        steps.append("alone \(describe(first))")
        let second = workspace.openPane(title: "pn3-b", command: report("b"))
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { second?.state.surfaceSize != nil }
        await harness.pause(.milliseconds(600))
        steps.append("split \(describe(first)) / \(second.map(describe) ?? "nil")")
        workspace.setLayout(.single)
        let firstBack = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            first.state.surfaceSize?.columns == alone?.columns && agrees(first, "a")
        }
        ok = ok && firstBack
        steps.append("single first \(describe(first)) pty \(pty("a"))")
        if let second {
            workspace.selectPane(id: second.id)
            let secondFull = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
                second.state.surfaceSize?.columns == alone?.columns && second.state.surfaceSize?.rows == alone?.rows && agrees(second, "b")
            }
            ok = ok && secondFull && workspace.panes.first?.id == second.id
            steps.append("single second \(describe(second)) pty \(pty("b"))")
            workspace.selectPane(id: first.id)
            let firstAgain = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
                first.state.surfaceSize?.columns == alone?.columns && first.state.surfaceSize?.rows == alone?.rows && agrees(first, "a")
            }
            ok = ok && firstAgain
            steps.append("single first again \(describe(first)) pty \(pty("a"))")
        } else {
            ok = false
        }
        return .make("PN-03a", "분할 뒤 1개 보기로 돌아가면 어느 터미널이든 혼자일 때 크기를 다시 씀",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["steps": steps.joined(separator: " | ")], startedAt: start)
    }

    /// PN-04a (2026-11-13 feedback on beta.7: list rows moved when an agent
    /// was clicked, and what each agent was on did not keep up): the list
    /// order is the start order whatever the slots do, and a row's work
    /// comes from the session file's task and newest log line.
    private func agentListKeepsOrder() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        var failures: [String] = []
        workspace.editInProgress = false
        workspace.destination = .sessions
        let panes = (1 ... 4).map { workspace.makePane(title: "pn4 \($0)", command: "sleep 60") }
        await harness.install(panes, layout: .double)
        let order = panes.map(\.id)
        workspace.selectPane(id: panes[3].id)
        if workspace.panes.prefix(2).contains(where: { $0.id == panes[3].id }) == false { failures.append("held pane not shown") }
        if workspace.panes.map(\.id) == order { failures.append("slots did not change") }
        if workspace.panesByStart.map(\.id) != order { failures.append("list moved after select") }
        workspace.show(panes[2].id, inSlot: 0)
        workspace.setLayout(.quad)
        workspace.setLayout(.single)
        if workspace.panesByStart.map(\.id) != order { failures.append("list moved after slot change") }
        workspace.closePane(id: panes[1].id)
        if workspace.panesByStart.map(\.id) != [order[0], order[2], order[3]] { failures.append("list order after close") }

        let barrack = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-pn4-\(UUID().uuidString)")
        let sessions = barrack.appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: barrack) }
        let file = { (task: String, log: String) in
            "# Session: s1\n\n- **Client**: Claude Code\n- **Status**: active\n- **Task**: \(task)\n\n## Log\n<!-- note -->\n\(log)\n## Decisions\n- later\n"
        }
        try? file("(pending)", "").write(to: sessions.appendingPathComponent("s1.md"), atomically: true, encoding: .utf8)
        let fresh = AgentWork.read(barrackPath: barrack.path, sessions: ["s1", "absent"])
        if fresh["s1"] != AgentWork(task: "", latestLog: nil) || fresh["absent"] != nil { failures.append("fresh \(fresh)") }
        try? file("목록 고정", "- [07:10] 첫 일 → 끝\n- [07:20] 둘째 일 → 진행\n").write(to: sessions.appendingPathComponent("s1.md"), atomically: true, encoding: .utf8)
        let later = AgentWork.read(barrackPath: barrack.path, sessions: ["s1"])
        if later["s1"] != AgentWork(task: "목록 고정", latestLog: "[07:20] 둘째 일 → 진행") { failures.append("later \(later)") }
        return .make("PN-04a", "에이전트 목록: 칸을 바꿔도 시작 순서 그대로, 세션 파일의 작업·최근 로그를 읽음",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    private func describe(_ pane: TerminalPane) -> String {
        let size = pane.state.surfaceSize
        let frame = pane.probeView?.frame.size ?? .zero
        return "\(size?.columns ?? 0)x\(size?.rows ?? 0) view \(Int(frame.width))x\(Int(frame.height))"
    }

    /// Codex build-84 review F1: switching barracks during a scan left the
    /// old barrack's items, runnable, under the new one, and dropped the new
    /// barrack's scan.
    private func maintenanceFollowsBarrack() async -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let a = Barrack(name: "mt-a", path: "/tmp/aibcc-mt-a", description: nil)
        let b = Barrack(name: "mt-b", path: "/tmp/aibcc-mt-b", description: nil)
        let store = MaintenanceStore { barrack in
            if barrack.name == "mt-a" { try? await Task.sleep(for: .milliseconds(400)) }
            return [MaintenanceItem(kind: .clean, title: "from \(barrack.name)", count: 1, details: [barrack.path], command: "true")]
        }
        let slowA = Task { await store.scan(a) }
        try? await Task.sleep(for: .milliseconds(50))
        if !store.items(for: b).isEmpty { failures.append("b shows items before its scan") }
        await store.scan(b)
        await slowA.value
        if store.items(for: b).map(\.title) != ["from mt-b"] { failures.append("b items \(store.items(for: b).map(\.title))") }
        if !store.items(for: a).isEmpty { failures.append("a's late result kept") }
        if store.isScanning(b) || store.isScanning(a) { failures.append("still scanning") }
        // Back to a mid-scan of b: the later request wins again.
        let slowAgain = Task { await store.scan(a) }
        try? await Task.sleep(for: .milliseconds(50))
        if !store.items(for: a).isEmpty { failures.append("a shows b's items") }
        await slowAgain.value
        if store.items(for: a).map(\.title) != ["from mt-a"] { failures.append("a items \(store.items(for: a).map(\.title))") }
        return .make("MT-01d", "점검 중 배럭 전환: 결과·실행 대상이 그 배럭에만, 늦게 온 결과는 버림, 새 요청은 실행",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// P0 across destinations: Git/Skills replace the terminals on screen;
    /// coming back shows the same shell, which still takes input.
    private func destinationRoundTrip() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        guard let recorder = harness.makeRecorderPane(name: "dest"), let window = harness.window else {
            return .make("DS-01a", "목적지 왕복", status: .fail, cause: .app, evidence: ["reason": "setup"], startedAt: start)
        }
        await harness.install([recorder.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorder.log.isReady }
        let pid = recorder.pane.processID
        for destination in [Destination.git, .skills, .council, .rules] {
            workspace.destination = destination
            await harness.pause(.milliseconds(400))
        }
        let detached = recorder.pane.probeView?.window == nil
        workspace.destination = .sessions
        let back = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { recorder.pane.probeView?.window != nil }
        await harness.click(row: 2, column: 2, in: recorder.pane)
        let mark = recorder.log.mark()
        EventSynthesizer.type("ok", in: window)
        let typed = await harness.settledBytes(recorder.log, since: mark, expectingAtLeast: 2)
        let ok = detached && back && recorder.pane.processID == pid && typed == Hex.bytes("ok")
        return .make("DS-01a", "Git·Skills·Council·규칙을 거쳐 돌아와도 같은 셸·입력 정상",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["detached_while_away": "\(detached)", "reattached": "\(back)",
                                "same_process": "\(recorder.pane.processID == pid)", "typed": Hex.string(typed)],
                     startedAt: start)
    }

    /// Every sealed session of every barrack: our verdict vs `aib sessions
    /// verify --quiet` (which lists only the changed ones).
    private func sealsAgreeWithAib() async -> TestResult {
        let start = ContinuousClock.now
        var checked = 0
        var disagreements: [String] = []
        for barrack in harness.workspace.barracks {
            let seals = (try? FileManager.default.contentsOfDirectory(atPath: barrack.path + "/sessions/.seals")) ?? []
            guard !seals.isEmpty else { continue }
            let changed = Set(MaintenanceScanner.lines(await AibShell.run("aib sessions verify --quiet", in: barrack.path))
                .flatMap { $0.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) }
                .map(String.init))
            for seal in seals where seal.hasSuffix(".sha256") {
                let id = String(seal.dropLast(7))
                guard let detail = SessionRecords.detail(barrackPath: barrack.path, id: id) else { continue }
                checked += 1
                let aibSaysChanged = changed.contains(id)
                if (detail.seal != .intact) != aibSaysChanged { disagreements.append("\(barrack.name)/\(id)=\(detail.seal.rawValue)") }
            }
        }
        return .make("SR-01d", "실데이터 봉인 판정 = aib sessions verify (\(checked)건)",
                     status: disagreements.isEmpty ? (checked > 0 ? .pass : .unverified) : .fail, cause: .app,
                     evidence: ["checked": "\(checked)", "disagreements": disagreements.prefix(10).joined(separator: ",")],
                     startedAt: start)
    }

    /// A ⌘K hit lands on its document: barrack, destination, selection.
    private func searchHitOpens() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        guard let barrack = workspace.selectedBarrack,
              let topic = BarrackDocuments.firstWikiTopic(in: barrack.url) else {
            return .make("PL-01a", "검색 결과 열기", status: .unverified, evidence: ["reason": "no wiki topic"], startedAt: start)
        }
        workspace.open(SearchHit(barrackID: barrack.id, barrackName: barrack.name, source: .wiki,
                                 title: topic.lastPathComponent, snippet: "", file: topic))
        let consumed = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { workspace.pendingDocument == nil }
        let ok = workspace.destination == .wiki && consumed
        workspace.destination = .sessions
        await harness.pause(.milliseconds(400))
        return .make("PL-01a", "검색 결과 → 해당 배럭·Wiki 목적지·토픽 선택",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["destination": workspace.destination.rawValue, "consumed": "\(consumed)"], startedAt: start)
    }

    private func noticeActionLands() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        guard let other = workspace.barracks.last, let original = workspace.selectedBarrackID else {
            return .make("NC-01a", "알림 동작", status: .unverified, startedAt: start)
        }
        workspace.destination = .wiki
        let notice = AppNotice(kind: .attention, title: "t", body: "b", actionLabel: "이동", barrackID: other.id, sessionID: nil)
        workspace.notices.post(notice)
        let shown = workspace.notices.notices.contains { $0.id == notice.id }
        workspace.perform(notice)
        let ok = shown && workspace.selectedBarrackID == other.id && workspace.destination == .sessions
            && !workspace.notices.notices.contains { $0.id == notice.id }
        workspace.selectedBarrackID = original
        await harness.pause(.milliseconds(500))
        return .make("NC-01a", "알림 토스트 표시 → 동작: 해당 배럭 터미널로 이동, 토스트 닫힘",
                     status: ok ? .pass : .fail, cause: .app, evidence: ["shown": "\(shown)"], startedAt: start)
    }

    /// v1 file-changed: a write under the watched barrack reaches the views.
    private func fileEventsRefresh() async -> TestResult {
        let start = ContinuousClock.now
        let store = harness.artifacts
        let previous = store.watchedRoot
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-fe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        store.watch(root: root)
        await harness.pause(.milliseconds(500))
        let before = store.fileEvents
        try? "# new".write(to: root.appendingPathComponent("RULES.md"), atomically: true, encoding: .utf8)
        let seen = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { store.fileEvents > before }
        store.watch(root: previous)
        return .make("AR-01a", "배럭 파일 변경이 문서·기록 화면 새로고침 신호로 전달됨",
                     status: seen ? .pass : .fail, cause: .app, startedAt: start)
    }

    private func registryReload() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        let original = workspace.barracks
        guard original.count >= 2 else { return .make("RG-02a", "레지스트리", status: .unverified, startedAt: start) }
        let selected = workspace.selectedBarrackID
        workspace.selectedBarrackID = original[0].id
        workspace.reloadRegistry(Array(original.dropFirst()))
        let removedHandled = workspace.barracks.count == original.count - 1 && workspace.selectedBarrackID == original[1].id
        workspace.reloadRegistry(original)
        workspace.selectedBarrackID = selected
        await harness.pause(.milliseconds(500))
        let restored = workspace.barracks == original
        return .make("RG-02a", "배럭 레지스트리 변경 반영(제거된 배럭을 보던 중이면 첫 배럭으로)",
                     status: removedHandled && restored ? .pass : .fail, cause: .app, startedAt: start)
    }

    /// Quick Command typed into a pane, full-text read, bring to front,
    /// close (process ends, preset shrinks).
    private func terminalManagement() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        guard let a = harness.makeRecorderPane(name: "tm-a"), let b = harness.makeRecorderPane(name: "tm-b"),
              let c = harness.makeRecorderPane(name: "tm-c") else {
            return .make("TT-01b", "터미널 관리", status: .fail, cause: .app, evidence: ["reason": "setup"], startedAt: start)
        }
        await harness.install([a.pane, b.pane, c.pane], layout: .double)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { a.log.isReady && b.log.isReady }
        let mark = a.log.mark()
        workspace.confirmSend(QuickCommand(label: "t", command: "abc"), to: a.pane, program: ProcessTree.foreground(of: a.pane.processID))
        let typed = await harness.settledBytes(a.log, since: mark, expectingAtLeast: 4)
        let text = a.pane.probeView?.readScreenText() ?? ""
        workspace.bringToFront(id: c.pane.id)
        let front = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            workspace.panes.first?.id == c.pane.id && c.pane.probeView?.window != nil
        }
        let pid = b.pane.processID ?? 0
        workspace.closePane(id: b.pane.id)
        let ended = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { !ProcessCWD.isAlive(pid) }
        let ok = typed == Hex.bytes("abc\r") && text.contains("TL") && text.contains("BR") && front && ended
            && workspace.panes.count == 2 && workspace.layout == .double
        return .make("TT-01b", "Quick Command 입력·전체 텍스트 읽기·숨은 터미널 앞으로·닫기(프로세스 종료)",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["typed": Hex.string(typed), "text_has_markers": "\(text.contains("TL") && text.contains("BR"))",
                                "front": "\(front)", "closed_process_ended": "\(ended)", "panes": "\(workspace.panes.count)"],
                     startedAt: start)
    }

    /// Codex r4: one failed session list at launch let the fresh grid be
    /// saved over the layout, and the next launch killed the still-running
    /// sessions as orphans. A model on an unreachable daemon must keep them.
    /// AG-02a (2026-11-10 feedback: a shell started by default got in the
    /// way): a barrack's Agents start empty, a wider layout adds empty slots
    /// rather than shells, a started terminal fills a slot, and closing the
    /// last one leaves the grid empty instead of a new shell.
    private func agentsStartEmpty() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let barrack = Barrack(name: "empty", path: directory.path, description: nil)
        let model = WorkspaceModel(barracks: [barrack], daemon: nil)
        model.selectedBarrackID = barrack.id
        if !model.panes.isEmpty { failures.append("opened with \(model.panes.count) panes") }
        model.setLayout(.quad)
        if !model.panes.isEmpty || model.layout != .quad { failures.append("layout added shells (\(model.panes.count))") }
        let pane = model.launchAgent(.terminal, skipPermissions: false)
        if pane == nil || model.panes.count != 1 || model.layout != .quad { failures.append("start did not fill a slot") }
        if let pane { model.closePane(id: pane.id) }
        if !model.panes.isEmpty { failures.append("closing the last left \(model.panes.count) panes") }
        return .make("AG-02a", "Agents는 빈 화면으로 시작(기본 셸 없음): 분할은 빈 칸만, 시작하면 칸을 채우고, 마지막을 닫으면 다시 빈 화면",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    private func restoreFailureKeepsSessions() -> TestResult {
        let start = ContinuousClock.now
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("b"), withIntermediateDirectories: true)
        let barrack = Barrack(name: "b", path: directory.appendingPathComponent("b").path, description: nil)
        let executable = harness.workspace.daemon?.executable ?? Bundle.main.bundleURL
        let backend = DaemonBackend(socketPath: directory.appendingPathComponent("absent.sock").path, executable: executable)
        let live = UUID()
        let saved = SavedWorkspace(selectedBarrackID: barrack.id, grids: [barrack.id: .init(
            layout: PaneLayout.single.paneCount, splitX: 0.5, splitY: 0.5, panes: [.init(session: live, title: "agent")])])
        SessionStore.save(saved, to: backend.sessionStoreURL)
        let model = WorkspaceModel(barracks: [barrack], daemon: backend)
        let after = SessionStore.load(from: backend.sessionStoreURL)?.grids[barrack.id]?.panes.map(\.session) ?? []
        let ok = after.contains(live) && model.restoreSummary.contains("kept")
        return .make("PS-03a", "복원 시 세션 목록 실패: 저장된 세션 참조 유지(다음 실행에 고아로 종료되지 않음)",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["sessions_after": after.map(\.uuidString).joined(separator: ","), "restore": model.restoreSummary],
                     startedAt: start)
    }

    /// Codex r5: ⌘K, the barrack list and the destinations left an open
    /// edit without asking (only the document list asked).
    private func navigationGuard() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        var failures: [String] = []
        workspace.destination = .sessions
        workspace.editInProgress = true
        workspace.navigate { workspace.destination = .wiki }
        if workspace.destination != .sessions || !workspace.isConfirmingNavigation { failures.append("navigated without asking") }
        workspace.cancelNavigation()
        if workspace.destination != .sessions || !workspace.editInProgress { failures.append("cancel") }
        workspace.navigate { workspace.destination = .wiki }
        workspace.confirmNavigation()
        if workspace.destination != .wiki || workspace.editInProgress { failures.append("confirm") }
        workspace.navigate { workspace.destination = .sessions }
        if workspace.destination != .sessions || workspace.isConfirmingNavigation { failures.append("asked with no edit") }
        return .make("NV-01a", "편집 중 이동(사이드바·배럭·⌘K·알림)은 먼저 확인, 취소하면 그대로·확인하면 이동",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// Codex r6: ⌘⇧A's target, the pane menu, notices and new panes moved
    /// the user straight past an open edit; a discard left the editor dirty.
    private func modelEntryPointsAsk() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        var failures: [String] = []
        workspace.editInProgress = false
        workspace.destination = .sessions
        if workspace.panes.isEmpty { await harness.install([workspace.makePane(title: "nv-shell")], layout: .single) }
        workspace.destination = .rules
        workspace.editInProgress = true
        let asks = { (label: String, action: () -> Void) in
            action()
            if workspace.destination != .rules || !workspace.isConfirmingNavigation { failures.append(label) }
            workspace.cancelNavigation()
        }
        let pane = workspace.panes.first
        if let pane { asks("pane menu") { workspace.bringToFront(id: pane.id) } } else { failures.append("no pane") }
        asks("notice") {
            workspace.perform(AppNotice(kind: .stale, title: "t", body: "", actionLabel: nil,
                                        barrackID: workspace.selectedBarrackID, sessionID: nil))
        }
        asks("new pane") { _ = workspace.runInPane(title: "nv", command: "true") }
        let revision = workspace.discardRevision
        if let pane { workspace.bringToFront(id: pane.id) }
        workspace.confirmNavigation()
        if workspace.discardRevision != revision + 1 || workspace.editInProgress || workspace.destination != .sessions {
            failures.append("discard \(workspace.discardRevision - revision) \(workspace.destination)")
        }
        return .make("NV-01b", "모델 진입점(⌘⇧A·pane 메뉴·알림·새 pane)도 편집 중 이동 확인, 버리면 편집 버퍼도 초기화",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// Codex r7: a Quick Command was typed, and a new pane made and saved,
    /// while "leave the edit?" was still on screen; "cancel" kept both.
    private func nothingBeforeConfirm() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        var failures: [String] = []
        guard let recorder = harness.makeRecorderPane(name: "nv-quick") else {
            return .make("NV-01c", "확인 전 부작용 없음", status: .fail, cause: .app, evidence: ["reason": "no recorder"], startedAt: start)
        }
        workspace.editInProgress = false
        workspace.destination = .sessions
        await harness.install([recorder.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorder.log.isReady }
        let quick = QuickCommand(label: "nv", command: "nvq")
        workspace.destination = .rules
        workspace.editInProgress = true
        let mark = recorder.log.mark()
        workspace.confirmSend(quick, to: recorder.pane, program: ProcessTree.foreground(of: recorder.pane.processID))
        let paneCount = workspace.panes.count
        _ = workspace.runInPane(title: "nv-new", command: "true")
        await harness.pause(AppConstants.SelfTest.changeGrace)
        if !recorder.log.bytes(since: mark).isEmpty { failures.append("typed before confirm") }
        if workspace.panes.count != paneCount { failures.append("pane made before confirm") }
        await harness.settleSheet(shown: true)
        workspace.cancelNavigation()
        await harness.settleSheet(shown: false)
        if !recorder.log.bytes(since: mark).isEmpty || workspace.panes.count != paneCount { failures.append("cancel left effects") }
        // Confirmed, the command runs.
        workspace.editInProgress = true
        workspace.confirmSend(quick, to: recorder.pane, program: ProcessTree.foreground(of: recorder.pane.processID))
        workspace.confirmNavigation()
        let typed = await harness.settledBytes(recorder.log, since: mark, expectingAtLeast: 3)
        if !String(decoding: typed, as: UTF8.self).contains("nvq") { failures.append("confirmed run missing \(Hex.string(typed))") }
        return .make("NV-01c", "편집 중 Quick Command·새 pane은 확인 전 아무것도 안 함, 취소 시 부작용 없음, 확인 시 실행",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// v1 C7: closing a pane keeps its screen text in the (self-test) archive.
    private func archiveOnClose() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        guard let recorder = harness.makeRecorderPane(name: "archive") else {
            return .make("SB-01b", "닫은 pane 출력 보관", status: .fail, cause: .app, evidence: ["reason": "setup"], startedAt: start)
        }
        await harness.install([recorder.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorder.log.isReady }
        let id = recorder.pane.archiveID
        workspace.closePane(id: recorder.pane.id)
        let text = workspace.scrollback.text(of: id) ?? ""
        let entry = workspace.scrollback.list().first { $0.id == id }
        let isolated = workspace.scrollback.directory.lastPathComponent == AppConstants.Scrollback.selfTestDirectory
        let ok = text.contains("TL") && text.contains("BR") && entry?.barrackPath == workspace.selectedBarrack?.path && isolated
        workspace.deleteArchived(id)
        return .make("SB-01b", "pane을 닫으면 화면 내용이 보관됨(배럭 경로 포함, 테스트 전용 보관소)",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["markers": "\(text.contains("TL") && text.contains("BR"))", "entry": "\(entry != nil)",
                                "isolated": "\(isolated)"], startedAt: start)
    }

    private func settingsApply() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        guard let recorder = harness.makeRecorderPane(name: "settings") else {
            return .make("SE-01a", "설정", status: .fail, cause: .app, evidence: ["reason": "setup"], startedAt: start)
        }
        await harness.install([recorder.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorder.log.isReady }
        let before = recorder.pane.state.surfaceSize?.columns ?? 0
        workspace.applySettings(AppSettings.Terminal(fontSize: 20, cursor: .bar, fontFamily: ""))
        let grew = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            (recorder.pane.state.surfaceSize?.columns ?? 0) < before
        }
        let larger = recorder.pane.state.surfaceSize?.columns ?? 0
        workspace.applySettings(AppSettings.Terminal())
        let restored = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            recorder.pane.state.surfaceSize?.columns == before
        }
        return .make("SE-01a", "설정의 글꼴 크기가 열린 터미널에 바로 적용되고 되돌아감",
                     status: grew && restored ? .pass : .fail, cause: .app,
                     evidence: ["columns": "\(before) → \(larger) → \(recorder.pane.state.surfaceSize?.columns ?? 0)"],
                     startedAt: start)
    }

    /// SP-01b (Codex parity audit P02): the top/bottom split gives each of
    /// two terminals the full width and half the height, and is saved by name.
    private func twoRowsLayout() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        guard let a = harness.makeRecorderPane(name: "rows-a"), let b = harness.makeRecorderPane(name: "rows-b") else {
            return .make("SP-01b", "상하 2분할", status: .fail, cause: .app, evidence: ["reason": "setup"], startedAt: start)
        }
        await harness.install([a.pane, b.pane], layout: .double)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { a.log.isReady && b.log.isReady }
        let size = { (pane: TerminalPane) in (Int(pane.state.surfaceSize?.columns ?? 0), Int(pane.state.surfaceSize?.rows ?? 0)) }
        let columns = size(a.pane)
        workspace.setLayout(.twoRows)
        let changed = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            size(a.pane).0 > columns.0 * 3 / 2 && size(a.pane).1 < columns.1 * 3 / 4 && size(b.pane).0 == size(a.pane).0
        }
        let rows = (size(a.pane), size(b.pane))
        var saved = "no daemon"
        if let daemon = workspace.daemon, let barrack = workspace.selectedBarrackID {
            let grid = SessionStore.load(from: daemon.sessionStoreURL)?.grids[barrack]
            saved = "\(grid?.layoutName ?? "nil")/\(grid?.layout ?? 0)"
        }
        workspace.setLayout(.double)
        let ok = changed && (saved == "twoRows/2" || saved == "no daemon")
        return .make("SP-01b", "상하 2분할: 두 터미널이 전체 폭·절반 높이, 세션 기록에 이름으로 저장",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["left_right": "\(columns)", "top_bottom": "\(rows)", "saved": saved], startedAt: start)
    }

    /// SE-01b (Codex parity audit P04): line height 2.0 about halves the
    /// rows of an open terminal (cells twice as tall), and 1.0 restores them.
    private func lineHeightApplies() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        guard let recorder = harness.makeRecorderPane(name: "line-height") else {
            return .make("SE-01b", "줄 간격", status: .fail, cause: .app, evidence: ["reason": "setup"], startedAt: start)
        }
        await harness.install([recorder.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorder.log.isReady }
        let rows = { Int(recorder.pane.state.surfaceSize?.rows ?? 0) }
        let before = rows()
        workspace.applySettings(AppSettings.Terminal(lineHeight: 2.0))
        let shrank = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { rows() > 0 && rows() < before }
        let doubled = rows()
        workspace.applySettings(AppSettings.Terminal())
        let restored = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { rows() == before }
        let halved = before > 0 && abs(Double(doubled) - Double(before) / 2) <= 1.5
        let mapped = TerminalAppearance.cellHeight(1.2) == "20%" && TerminalAppearance.cellHeight(1.0) == nil
            && TerminalAppearance.cellHeight(2.6) == "100%" && TerminalAppearance.cellHeight(1.04) == nil
        return .make("SE-01b", "줄 간격(v1 1.0~2.0)이 열린 터미널에 바로 적용: 2.0이면 행 수 약 절반, 1.0으로 복귀",
                     status: shrank && halved && restored && mapped ? .pass : .fail, cause: .app,
                     evidence: ["rows": "\(before) → \(doubled) → \(rows())", "mapping": "\(mapped)"], startedAt: start)
    }

    private func matchesPaneByProcess() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        guard let barrack = workspace.selectedBarrackID, let a = harness.makeRecorderPane(name: "match-a"),
              let b = harness.makeRecorderPane(name: "match-b")
        else { return .make("AT-01c", "pane 매칭", status: .fail, cause: .app, evidence: ["reason": "setup"], startedAt: start) }
        await harness.install([a.pane, b.pane], layout: .double)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { a.pane.processID != nil && b.pane.processID != nil }
        let session = LiveSession(id: "t", state: .blocked, ageSeconds: 0, pid: b.pane.processID ?? 0, cwd: nil)
        let matched = workspace.pane(running: session, in: barrack)
        let none = workspace.pane(running: LiveSession(id: "x", state: .blocked, ageSeconds: 0, pid: 1, cwd: nil), in: barrack)
        let ok = matched?.id == b.pane.id && none == nil
        return .make("AT-01c", "⌘⇧A: 에이전트 pid를 가진 pane을 찾음(다른 pane·무관 pid는 아님)",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["matched": matched?.title ?? "nil", "unrelated": none?.title ?? "nil"], startedAt: start)
    }
}
