import AppKit

/// M3 in the real window: ⌘N grows the preset and focuses the new pane;
/// ⌘⇧A finds the pane that runs an agent by process tree. Uses the
/// "터미널" client so no real agent starts.
@MainActor
struct AgentSuite {
    let harness: SelfTestHarness

    func run() async -> [TestResult] {
        [await launchGrowsAndFocuses(), await shortcutReachesMenu(), await matchesPaneByProcess(),
         await maintenanceRunsInPane(), await maintenanceScanCompletes(), await maintenanceFollowsBarrack(), await fullGridMakesRoom(), await destinationRoundTrip(),
         await sealsAgreeWithAib(), await searchHitOpens(), await noticeActionLands(), await fileEventsRefresh(),
         await registryReload(), await terminalManagement(), await archiveOnClose(), await navigationGuard(), await modelEntryPointsAsk(), await nothingBeforeConfirm(), restoreFailureKeepsSessions(),
         await settingsApply()]
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

    /// Codex build-84 review: four empty shells blocked every new agent, and
    /// a full grid of busy panes made maintenance and Council do nothing
    /// without a word.
    private func fullGridMakesRoom() async -> TestResult {
        let start = ContinuousClock.now
        let workspace = harness.workspace
        var failures: [String] = []
        workspace.editInProgress = false
        workspace.destination = .sessions
        let shells = (1 ... 4).map { workspace.makePane(title: "pn shell \($0)") }
        await harness.install(shells, layout: .quad)
        let idle = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { shells.allSatisfy(\.isIdleShell) }
        if !idle { failures.append("shells not idle \(shells.map(\.isIdleShell))") }
        let launched = workspace.runInPane(title: "pn-busy", command: "sleep 30")
        let ids = Set(workspace.panes.map(\.id))
        if launched == nil || !ids.contains(launched?.id ?? UUID()) || workspace.panes.count != 4 {
            failures.append("no room taken (\(workspace.panes.count) panes)")
        }
        if shells.filter({ ids.contains($0.id) }).count != 3 { failures.append("not exactly one shell replaced") }
        let busy = (1 ... 4).map { workspace.makePane(title: "pn busy \($0)", command: "sleep 30") }
        await harness.install(busy, layout: .quad)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { busy.allSatisfy { $0.processID != nil } }
        let before = workspace.notices.notices.filter { $0.kind == .panes }.count
        let refused = workspace.runInPane(title: "pn-refused", command: "true")
        let after = workspace.notices.notices.filter { $0.kind == .panes }.count
        if refused != nil || workspace.panes.count != 4 { failures.append("busy grid accepted a pane") }
        if after != before + 1 { failures.append("no notice for a full grid") }
        workspace.notices.notices.filter { $0.kind == .panes }.forEach { workspace.notices.dismiss($0.id) }
        return .make("PN-01a", "4칸이 빈 셸이면 그 자리에서 시작, 모두 바쁘면 거부하고 알림",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
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
        workspace.run(QuickCommand(label: "t", command: "abc"), in: a.pane)
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
            layout: PaneLayout.single.rawValue, splitX: 0.5, splitY: 0.5, panes: [.init(session: live, title: "agent")])])
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
        await harness.install([recorder.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorder.log.isReady }
        let quick = QuickCommand(label: "nv", command: "nvq")
        workspace.destination = .rules
        workspace.editInProgress = true
        let mark = recorder.log.mark()
        _ = workspace.run(quick, in: recorder.pane)
        let paneCount = workspace.panes.count
        _ = workspace.runInPane(title: "nv-new", command: "true")
        await harness.pause(AppConstants.SelfTest.changeGrace)
        if !recorder.log.bytes(since: mark).isEmpty { failures.append("typed before confirm") }
        if workspace.panes.count != paneCount { failures.append("pane made before confirm") }
        workspace.cancelNavigation()
        await harness.pause(AppConstants.SelfTest.changeGrace)
        if !recorder.log.bytes(since: mark).isEmpty || workspace.panes.count != paneCount { failures.append("cancel left effects") }
        // Confirmed, the command runs.
        workspace.editInProgress = true
        _ = workspace.run(quick, in: recorder.pane)
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
