import SwiftUI
import AppKit

/// Pure checks that need no window: the liveness fold must match aib
/// (`aib sessions state`, CC v1.6.1 `live::fold` test matrix), and the
/// sidecar reader must apply the ack file.
@MainActor
struct UnitSuite {
    func run() -> [TestResult] {
        [foldMatrix(), readerAppliesAck(), attentionWindow(), commentsHidden(), launchCommand(), ackRoundTrip(),
         processTree(), maintenanceParsing(), socketChoice(), skillsAndCouncil(), editingPolicy(), editingConflict(),
         sessionParsing(), sealStatuses(), sessionCommands(), searchSemantics(), healthRules(), attentionTransitions(), terminalTools(),
         terminalOwnsControlKeys(), ruleCount(), hideEmptySessions(), wikiIndex(), paneLayouts(), panePlacement()]
    }

    private func terminalTools() -> TestResult {
        let start = ContinuousClock.now
        let escaped = GhosttyText.escape("a\\b \"q\" 한글\u{1b}")
        let action = GhosttyText.action(typing: "ls -l", pressEnter: true)
        let suite = "aibcc-qc-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuickCommandStore(defaults: defaults)
        store.add(label: "", command: "  git status  ")
        store.add(label: "up", command: "docker compose up")
        store.add(label: "x", command: "   ")
        if let first = store.commands.first { store.remove(first.id) }
        let reloaded = QuickCommandStore(defaults: defaults).commands.map(\.label)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-ex-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_793_500_000)
        let name = TerminalExport.fileName(title: "claude/a b", now: now)
        let written = TerminalExport.write("output", barrackPath: root.path, title: "t", now: now)
        let empty = TerminalExport.write("  \n", barrackPath: root.path, title: "t", now: now)
        let again = TerminalExport.write("output", barrackPath: root.path, title: "t", now: now)
        let decoy = root.appendingPathComponent("sessions/" + TerminalExport.fileName(title: "s", now: now))
        try? FileManager.default.createSymbolicLink(at: decoy, withDestinationURL: URL(fileURLWithPath: "/tmp/aibcc-outside"))
        let symlink = TerminalExport.write("output", barrackPath: root.path, title: "s", now: now)
        let ok = escaped == "a\\\\b \\\"q\\\" 한글\\x1b" && action == "text:ls -l\\r"
            && reloaded == ["up"] && name.hasPrefix("terminal-claude_a_b-") && name.hasSuffix(".txt")
            && (try? written.get())?.lastPathComponent.hasPrefix("terminal-t-") == true
            && empty == .failure(.empty) && again == .failure(.exists) && symlink == .failure(.exists)
            && !FileManager.default.fileExists(atPath: "/tmp/aibcc-outside")
        return .make("TT-01a", "Quick Command 저장·삭제·재로드, Ghostty text 이스케이프, 출력 내보내기(위치·빈 출력·덮어쓰기·심볼릭 링크 거부)",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["escaped": escaped, "reloaded": reloaded.joined(separator: ","), "name": name], startedAt: start)
    }

    /// CC v1.6.1 watcher rules on a real-shaped SESSIONS.md, plus v2's
    /// sync dedupe (v1 re-announced every 30 s).
    private func healthRules() -> TestResult {
        let start = ContinuousClock.now
        let index = """
        # Active Sessions
        | Session ID | Client | Started | Last Update | Working On |
        |------------|--------|---------|-------------|------------|
        | claude-1 | Claude Code | 10-24 10:13 | 10-24 10:13 | (starting) |
        | codex-2 | Codex CLI | 10-25 09:00 | 10-25 09:30 | 리뷰 |
        """
        let active = HealthRules.activeSessions(fromSessionsIndex: index)
        let now = Date()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-hm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try? index.write(to: root.appendingPathComponent("SESSIONS.md"), atomically: true, encoding: .utf8)
        for (id, age) in [("claude-1", 3.0 * 3600), ("codex-2", 600.0)] {
            let file = root.appendingPathComponent("sessions/\(id).md")
            try? "x".write(to: file, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
        }
        try? "aib_version: 1.5.0".write(to: root.appendingPathComponent("agent.yaml"), atomically: true, encoding: .utf8)
        let barrack = Barrack(name: "b", path: root.path, description: nil)
        let stale = HealthMonitor.staleSessions([barrack], now: now).map { "\($0.1.id):\($0.2)h" }
        let outdated = HealthMonitor.outdated([barrack], cliVersion: "1.6.0").count
        let first = HealthRules.shouldAnnounceSync(outdated: ["b"], cliVersion: "1.6.0", last: nil, now: now)
        let signature = HealthRules.syncSignature(outdated: ["b"], cliVersion: "1.6.0")
        let repeatSoon = HealthRules.shouldAnnounceSync(outdated: ["b"], cliVersion: "1.6.0", last: (signature, now), now: now.addingTimeInterval(30))
        let changed = HealthRules.shouldAnnounceSync(outdated: ["b", "c"], cliVersion: "1.6.0", last: (signature, now), now: now.addingTimeInterval(30))
        let suppressed = !HealthRules.shouldNotify(key: "k", notified: ["k": now], now: now.addingTimeInterval(600))
        let ok = active.map(\.id) == ["claude-1", "codex-2"] && active[0].task == "(no task recorded)" && active[1].task == "리뷰"
            && stale == ["claude-1:3h"] && outdated == 1 && first && !repeatSoon && changed && suppressed
        return .make("HM-01a", "Health 규칙 = v1(SESSIONS.md 활성 행, 2시간 stale, 1시간 억제, 버전 drift) + sync 알림 중복 제거",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["active": active.map(\.id).joined(separator: ","), "stale": stale.joined(separator: ","),
                                "outdated": "\(outdated)", "repeat_soon": "\(repeatSoon)"], startedAt: start)
    }

    private func attentionTransitions() -> TestResult {
        let start = ContinuousClock.now
        let session = { (id: String, state: Liveness) in LiveSession(id: id, state: state, ageSeconds: 5, pid: 1, cwd: nil) }
        let first = HealthRules.newlyNeedingAttention(previous: nil, current: ["b": [session("a", .done)]])
        let fresh = HealthRules.newlyNeedingAttention(previous: ["b": [session("a", .working)]], current: ["b": [session("a", .blocked)]])
        let again = HealthRules.newlyNeedingAttention(previous: ["b": [session("a", .blocked)]], current: ["b": [session("a", .blocked)]])
        let next = HealthRules.newlyNeedingAttention(previous: ["b": [session("a", .blocked)]], current: ["b": [session("a", .done)]])
        let ok = first.isEmpty && fresh.map(\.id) == ["a"] && again.isEmpty && next.map(\.state) == [.done]
            && SyncAll.command(quotedPaths: "'/a' '/b'").hasPrefix("for p in '/a' '/b'; do aib sync --dry-run \"$p\"; done && printf")
        return .make("HM-01b", "주의 알림: 첫 화면은 조용히, 새로 blocked·done이 된 것만, 같은 상태는 다시 알리지 않음",
                     status: ok ? .pass : .fail, cause: .app, startedAt: start)
    }

    /// CC v1.6.1 search_all: sources, case, 3 per file, snippet, min query.
    private func searchSemantics() -> TestResult {
        let start = ContinuousClock.now
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in ["sessions", "wiki/topics"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let write = { (path: String, body: String) in
            try? body.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        write("sessions/claude-1.md", "Ghostty one\nghostty two\nGHOSTTY three\nghostty four")
        write("wiki/topics/t.md", "about ghostty " + String(repeating: "x", count: 200))
        write("RULES.md", "rule ghostty")
        write("SOUL.md", "nothing")
        write("GROWTH.md", "growth ghostty")
        let barrack = Barrack(name: "b", path: root.path, description: nil)
        let hits = SearchIndex.search("GhOsTtY", in: [barrack])
        let bySource = Dictionary(grouping: hits, by: \.source).mapValues(\.count)
        let wikiSnippet = hits.first { $0.source == .wiki }?.snippet ?? ""
        let ok = bySource[.session] == 3 && bySource[.wiki] == 1 && bySource[.rules] == 1 && bySource[.config] == 1
            && wikiSnippet.hasSuffix("...") && wikiSnippet.count == 123
            && SearchIndex.search("g", in: [barrack]).isEmpty
            && !PaletteCommands.matches(PaletteItem(id: "barrack-x", title: "배럭: x", detail: "", symbol: "", section: "", run: {}), "")
            && PaletteCommands.matches(PaletteItem(id: "aib-sync", title: "aib sync", detail: "", symbol: "", section: "", run: {}), "SYNC")
        return .make("SR-02a", "⌘K 검색 = v1 search_all 규칙(출처 5종·대소문자·파일당 3개·120자 발췌·2자 미만 없음), 명령 필터",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["counts": bySource.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ","),
                                "snippet_len": "\(wikiSnippet.count)"], startedAt: start)
    }

    /// Incident class: reading after exit deadlocks past the pipe buffer.
    func runAsync() async -> [TestResult] {
        let start = ContinuousClock.now
        let output = await ProcessOutput.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "head -c 300000 /dev/zero | tr '\\0' x"],
                                             in: NSTemporaryDirectory())
        let elapsed = (ContinuousClock.now - start).milliseconds
        return [.make("PO-01a", "자식 출력 300KB(파이프 버퍼 초과)를 멈춤 없이 읽음",
                      status: output.count == 300_000 && elapsed < 5000 ? .pass : .fail, cause: .app,
                      evidence: ["bytes": "\(output.count)", "ms": String(format: "%.0f", elapsed)], startedAt: start),
                await exitStatusBurst(), await descendantHoldsPipe()]
    }

    /// Codex r5: the exit grace began only after EOF, so a background
    /// descendant holding the pipe (`sleep 600 &`) held the caller for its
    /// whole life. Now: the root's exit ends the call and kills the group,
    /// and a deadline from the start bounds everything.
    private func descendantHoldsPipe() async -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let shell = URL(fileURLWithPath: "/bin/sh")
        let (output, status) = await ProcessOutput.runWithStatus(shell, ["-c", "sleep 600 & echo $!; exit 0"], in: NSTemporaryDirectory())
        let first = (ContinuousClock.now - start).milliseconds
        let pid = Int32(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        usleep(100_000)
        if status != 0 || first > 5000 { failures.append("held \(Int(first))ms status \(status)") }
        if pid <= 0 || kill(pid, 0) == 0 { failures.append("descendant survived") }
        let timed = ContinuousClock.now
        let (_, timedStatus) = await ProcessOutput.runWithStatus(shell, ["-c", "sleep 30"], in: NSTemporaryDirectory(), timeout: 1)
        if timedStatus != AppConstants.ChildProcess.unknownStatus || (ContinuousClock.now - timed).milliseconds > 4000 { failures.append("timeout") }
        return .make("PO-01c", "자식이 남긴 후손이 파이프를 잡아도 호출이 끝남(그룹 종료) · 시작 시점 기준 시간 제한",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// Incident 2026-11-02: a self-test hung for good in waitUntilExit after
    /// the child had exited. Many short children at once must all return,
    /// each with its own exit status.
    private func exitStatusBurst() async -> TestResult {
        let start = ContinuousClock.now
        let statuses = await withTaskGroup(of: (Int32, Int32).self) { group in
            for index in 0..<40 {
                let code = Int32(index % 5)
                group.addTask {
                    (code, await ProcessOutput.runWithStatus(URL(fileURLWithPath: "/bin/sh"), ["-c", "exit \(code)"], in: NSTemporaryDirectory()).status)
                }
            }
            var results: [(Int32, Int32)] = []
            for await result in group { results.append(result) }
            return results
        }
        let wrong = statuses.filter { $0.0 != $0.1 }
        let elapsed = (ContinuousClock.now - start).milliseconds
        return .make("PO-01b", "자식 40개 동시 실행: 모두 돌아오고 각자의 종료 코드(무한 대기 없음)",
                     status: statuses.count == 40 && wrong.isEmpty && elapsed < 10_000 ? .pass : .fail, cause: .app,
                     evidence: ["returned": "\(statuses.count)", "wrong": wrong.prefix(5).map { "\($0.0)->\($0.1)" }.joined(separator: ","),
                                "ms": String(format: "%.0f", elapsed)], startedAt: start)
    }

    private func foldMatrix() -> TestResult {
        let start = ContinuousClock.now
        let now = 1_000_000, stale = 180
        let ack = Liveness.Ack(runID: "r", timestamp: now)
        let cases: [(String, Int, Liveness.Ack?, Liveness.PidState, Liveness)] = [
            ("blocked", now - 99_999, nil, .alive, .blocked),
            ("blocked", now, nil, .unknown, .blocked),
            ("blocked", now, nil, .dead, .crashed),
            ("working", now, nil, .alive, .working),
            ("working", now - stale, nil, .alive, .working),
            ("working", now - stale - 1, nil, .alive, .workingStale),
            ("working", now - stale - 1, nil, .unknown, .workingStale),
            ("working", now, nil, .dead, .interrupted),
            ("done", now, nil, .alive, .done),
            ("done", now, nil, .dead, .done),
            ("done", now, ack, .alive, .idle),
            ("done", now, Liveness.Ack(runID: "other", timestamp: now), .alive, .done),
            ("done", now + 5, ack, .alive, .done),
            ("mystery", now, nil, .alive, .none),
        ]
        let failures = cases.enumerated().compactMap { index, item -> String? in
            let got = Liveness.fold(state: item.0, statusTimestamp: item.1, runID: "r", ack: item.2,
                                    now: now, pid: item.3, staleAfter: stale)
            return got == item.4 ? nil : "#\(index) \(item.0) → \(got.rawValue), expected \(item.4.rawValue)"
        }
        return .make("LV-01a", "liveness 접기 = aib 규칙(\(cases.count)개 조합)",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// Incident 2026-11-01: finishes 1 h–152 days old rang on five barracks.
    private func attentionWindow() -> TestResult {
        let start = ContinuousClock.now
        let window = AppConstants.Liveness.attentionWindow
        let session = { (state: Liveness, age: Int) in LiveSession(id: "s", state: state, ageSeconds: age, pid: 1, cwd: nil) }
        let cases: [(LiveSession, Bool)] = [
            (session(.done, 60), true), (session(.done, window + 1), false),
            (session(.crashed, 60), true), (session(.crashed, window + 1), false),
            (session(.blocked, window * 10), true), (session(.working, 0), false), (session(.idle, 0), false),
        ]
        let failures = cases.enumerated().filter { $0.element.0.needsAttention != $0.element.1 }.map { "#\($0.offset)" }
        return .make("LV-01c", "attention ring: blocked는 항상, done·crashed는 12시간 안만",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: ",")], startedAt: start)
    }

    /// aib metadata comments showed as literal text in document views.
    private func commentsHidden() -> TestResult {
        let start = ContinuousClock.now
        let source = "<!-- AIB:OWNERSHIP — [AUTO-GROW] x -->\n# Rules\nkeep <!-- inline --> this\n<!-- multi\nline -->\n```html\n<!-- in code -->\n```\nend"
        let expected = "# Rules\nkeep  this\n```html\n<!-- in code -->\n```\nend"
        let got = MarkdownSource.forDisplay(source)
        return .make("MD-08a", "aib 메타데이터 주석은 표시에서 빠지고 코드 블록 안 주석은 유지",
                     status: got == expected ? .pass : .fail, cause: .app,
                     evidence: ["got": got.replacingOccurrences(of: "\n", with: "⏎")], startedAt: start)
    }

    private func launchCommand() -> TestResult {
        let start = ContinuousClock.now
        let claude = AgentLauncher.command(for: .claude, skipPermissions: true)
        let codex = AgentLauncher.command(for: .codex, skipPermissions: false)
        let ok = claude == "/bin/zsh -lc 'aib start claude --skip-permissions; exec /bin/zsh -l'"
            && codex == "/bin/zsh -lc 'aib start codex; exec /bin/zsh -l'"
            && AgentLauncher.command(for: .terminal, skipPermissions: true) == nil
        return .make("AG-01a", "에이전트 시작 명령 = aib start <client> (로그인 셸, 종료 후 셸 유지)",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["claude": claude ?? "nil", "codex": codex ?? "nil"], startedAt: start)
    }

    /// Byte-compatible with CC v1.6.1 write_ack; done → idle; bad ids refused.
    private func ackRoundTrip() -> TestResult {
        let start = ContinuousClock.now
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-ack-\(UUID().uuidString)")
        let live = root.appendingPathComponent("sessions/.live")
        try? FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Int(Date().timeIntervalSince1970)
        try? "{\"session_id\":\"s1\",\"run_id\":\"r1\",\"state\":\"done\",\"ts\":\(now),\"pid\":0}"
            .write(to: live.appendingPathComponent("s1.status"), atomically: true, encoding: .utf8)
        let before = LivenessReader.read(barrackPath: root.path, now: now).first?.state
        let wrote = LivenessAck.write(barrackPath: root.path, sessionID: "s1", runID: "r1", now: now)
        let after = LivenessReader.read(barrackPath: root.path, now: now).first?.state
        let refused = !LivenessAck.write(barrackPath: root.path, sessionID: "../x", runID: "r", now: now)
            && !LivenessAck.write(barrackPath: root.path, sessionID: "", runID: "r", now: now)
        let ok = before == .done && wrote && after == .idle && refused
        return .make("AT-01a", "done 확인(ack): CC 호환 .ack 기록 → idle, 잘못된 세션 id 거부",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["before": before?.rawValue ?? "nil", "after": after?.rawValue ?? "nil",
                                "refused_bad_ids": "\(refused)"], startedAt: start)
    }

    /// PN-02a (P01, 2026-11-12 report: a fifth agent could not be started):
    /// no cap on terminals — a new one takes an empty slot, else the focused
    /// slot (the layout stays as the user set it), and the one it displaces
    /// stays held off screen; showing a held one swaps it into the slot.
    private func panePlacement() -> TestResult {
        struct Item: Identifiable, Equatable { let id: Int }
        let start = ContinuousClock.now
        var failures: [String] = []
        let items = (0 ..< 6).map(Item.init)
        let empty = PanePlacement.adding(items[0], to: [items[1]], layout: .double, focused: nil)
        if empty.map(\.id) != [1, 0] { failures.append("empty slot \(empty.map(\.id))") }
        // The layout is never grown for a new one (2026-11-13 feedback):
        // alone on screen, the new one takes that slot.
        let alone = PanePlacement.adding(items[5], to: [items[0], items[1], items[2]], layout: .single, focused: 0)
        if alone.map(\.id) != [5, 0, 1, 2] { failures.append("single \(alone.map(\.id))") }
        if PanePlacement.adding(items[5], to: [items[0]], layout: .single, focused: nil).map(\.id) != [5, 0] { failures.append("single unfocused") }
        let rows = PanePlacement.adding(items[5], to: [items[0], items[1]], layout: .twoRows, focused: 0)
        if rows.map(\.id) != [5, 1, 0] { failures.append("twoRows \(rows.map(\.id))") }
        let full = Array(items.prefix(4))
        let focused = PanePlacement.adding(items[4], to: full, layout: .quad, focused: 1)
        if focused.map(\.id) != [0, 4, 2, 3, 1] { failures.append("focused \(focused.map(\.id))") }
        let unfocused = PanePlacement.adding(items[5], to: focused, layout: .quad, focused: nil)
        if unfocused.map(\.id) != [0, 4, 2, 5, 3, 1] { failures.append("last slot \(unfocused.map(\.id))") }
        let stale = PanePlacement.adding(items[5], to: full, layout: .quad, focused: 7)
        if stale.map(\.id) != [0, 1, 2, 5, 3] { failures.append("stale focus \(stale.map(\.id))") }
        let shown = PanePlacement.showing(1, inSlot: 2, of: unfocused, layout: .quad)
        if shown.map(\.id) != [0, 4, 1, 5, 3, 2] { failures.append("show held \(shown.map(\.id))") }
        let swapped = PanePlacement.showing(5, inSlot: 0, of: shown, layout: .quad)
        if swapped.map(\.id) != [5, 4, 1, 0, 3, 2] { failures.append("swap visible \(swapped.map(\.id))") }
        if PanePlacement.showing(9, inSlot: 0, of: shown, layout: .quad) != shown
            || PanePlacement.showing(1, inSlot: 4, of: shown, layout: .quad) != shown {
            failures.append("bad id or slot changed panes")
        }
        // Closing one on screen: the others stay put, a held one fills in.
        let closed = PanePlacement.removing(4, from: shown, layout: .quad)
        if closed.map(\.id) != [0, 3, 1, 5, 2] { failures.append("close visible \(closed.map(\.id))") }
        if PanePlacement.removing(2, from: shown, layout: .quad).map(\.id) != [0, 4, 1, 5, 3]
            || PanePlacement.removing(0, from: Array(items.prefix(3)), layout: .quad).map(\.id) != [1, 2] {
            failures.append("close held or with room")
        }
        // The list beside a reader gives way first: at a minimum window the
        // reader keeps its width and the list narrows to its own minimum.
        typealias Split = ListDetailSplit<EmptyView, EmptyView>
        if Split.width(stored: 340, available: 435, detailMin: 320) != 120 || Split.width(stored: 340, available: 1000, detailMin: 320) != 340
            || Split.width(stored: 900, available: 1000, detailMin: 320) != 600 || Split.width(stored: 240, available: 700, detailMin: 480) != 220 {
            failures.append("list width beside a detail minimum")
        }
        return .make("PN-02a", "터미널 상한 없음: 빈 칸 → 지금 칸 순서로 놓고(분할은 바꾸지 않음) 밀린 터미널은 화면 밖에 유지, 화면 밖 터미널은 칸과 맞바꿈",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// SP-01a (Codex parity audit P02): the top/bottom split, saved by name
    /// and read back from older records; grids grow and shrink through the
    /// presets but keep a top/bottom split while it fits.
    private func paneLayouts() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        if [1, 2, 3, 4].map({ PaneLayout(slots: $0) }) != [.single, .double, nil, .quad] { failures.append("slots") }
        if PaneLayout.restored(name: "twoRows", slots: 2) != .twoRows || PaneLayout.restored(name: nil, slots: 2) != .double
            || PaneLayout.restored(name: "future", slots: 4) != .quad || PaneLayout.restored(name: "future", slots: 9) != .single {
            failures.append("restored")
        }
        let fits: [(Int, PaneLayout, PaneLayout)] = [
            (2, .twoRows, .twoRows), (3, .twoRows, .quad), (1, .twoRows, .single), (2, .single, .double),
            (2, .quad, .double), (4, .quad, .quad), (2, .double, .double),
        ]
        for (count, current, expected) in fits where PaneLayout.fitting(count, keeping: current) != expected {
            failures.append("fitting \(count) from \(current)")
        }
        let frames = PaneGridLayout(layout: .twoRows, splitX: 0.5, splitY: 0.5, spacing: 1)
            .paneFrames(in: CGRect(x: 0, y: 0, width: 100, height: 101))
        if frames != [CGRect(x: 0, y: 0, width: 100, height: 50), CGRect(x: 0, y: 51, width: 100, height: 50)] {
            failures.append("frames \(frames)")
        }
        let old = #"{"layout":2,"splitX":0.5,"splitY":0.5,"panes":[]}"#
        let grid = try? JSONDecoder().decode(SavedWorkspace.Grid.self, from: Data(old.utf8))
        if grid?.layoutName != nil || grid.map({ PaneLayout.restored(name: $0.layoutName, slots: $0.layout) }) != .double {
            failures.append("old record")
        }
        return .make("SP-01a", "상하 2분할(v1 Split V): 이름으로 저장, 옛 기록(1·2·4)·모르는 이름은 칸 수로, 자동 확대·축소는 맞으면 유지",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// WK-01a (Codex parity audit P10): Index.md's topic table and Log.md's
    /// latest lines, as v1 get_wiki_index read them.
    private func wikiIndex() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let index = """
        # LLM Wiki Index

        > note

        | Topic | File | Updated | Summary |
        |-------|------|---------|---------|
        | Beta | [b.md](topics/b.md) | 2026-11-08 | **굵게** 요약 | 파이프 |
        | Alpha | [a.md](topics/a.md) | 2026-10-01 |  |
        | Plain | topics/p.md | 2026-09-09 | 링크 없음 |

        ## Schema Rules
        | Topic | File | Updated | Summary |
        | Ignored | x.md | - | - |
        """
        let topics = WikiIndex.parse(index) ?? []
        if topics.map(\.name) != ["Beta", "Alpha", "Plain"] { failures.append("names \(topics.map(\.name))") }
        if topics.first?.file != "topics/b.md" || topics.last?.file != "topics/p.md" { failures.append("links") }
        if topics.first?.summary != "**굵게** 요약 | 파이프" || topics.first?.updated != "2026-11-08" { failures.append("summary \(topics.first?.summary ?? "")") }
        if WikiIndex.parse("# Index\n\nno table here\n") != nil { failures.append("no table read as table") }
        let log = "# Log\n\n> keep\n\n- [11-08] c\n\n- [11-07] b\n- [11-06] a\n- [11-05] z\n- [11-04] y\n- [11-03] x\n"
        if WikiIndex.recentChanges(log) != ["[11-08] c", "[11-07] b", "[11-06] a", "[11-05] z", "[11-04] y"] { failures.append("recent") }
        let wiki = WikiIndex(topics: topics, recentChanges: [])
        let files = ["z.md", "a.md", "b.md", "c.md"].map { URL(fileURLWithPath: "/w/topics/\($0)") }
        if wiki.ordered(files).map(\.lastPathComponent) != ["b.md", "a.md", "c.md", "z.md"] { failures.append("order") }
        if wiki.entry(for: files[1])?.name != "Alpha" || wiki.entry(for: files[0]) != nil { failures.append("entry") }
        return .make("WK-01a", "Wiki 목록 = Index.md 토픽 표(이름·요약·갱신일, Index 순서) + Log.md 최근 변경, 표가 없으면 파일 이름",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// HS-01a (Codex parity audit P09): v1's "empty 숨김" — not active and
    /// no task or "(pending)" — on top of the status and client filters.
    private func hideEmptySessions() -> TestResult {
        let start = ContinuousClock.now
        let make = { (id: String, client: String, status: String, task: String) in
            SessionRecord(id: id, client: client, started: "", ended: "", status: status, task: task, continues: "")
        }
        let records = [
            make("a", "Claude Code", "active", "(pending)"), make("b", "Claude Code", "completed", "(pending)"),
            make("c", "Codex", "completed", "  "), make("d", "Codex", "interrupted", "fix login"),
            make("e", "Claude Code", "completed", "write docs"),
        ]
        let ids = { (status: SessionHistoryView.StatusFilter, client: String, hide: Bool) in
            SessionHistoryView.filter(records, status: status, client: client, hideEmpty: hide).map(\.id).joined()
        }
        let cases: [(String, String)] = [
            (ids(.all, "all", true), "ade"), (ids(.all, "all", false), "abcde"),
            (ids(.completed, "all", true), "e"), (ids(.all, "Codex", true), "d"), (ids(.active, "all", true), "a"),
        ]
        let wrong = cases.enumerated().filter { $0.element.0 != $0.element.1 }.map { "case\($0.offset)=\($0.element.0)" }
        return .make("HS-01a", "빈 세션 숨기기 = v1(진행 중은 유지, 작업 없음·(pending) 숨김, 상태·클라이언트 필터와 함께)",
                     status: wrong.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["wrong": wrong.joined(separator: ",")], startedAt: start)
    }

    /// OV-02a: Info counts every rule bullet, sub-sections included, and no
    /// bullet inside a code fence (Codex build-84 review: the form-managed
    /// lists alone undercounted).
    private func ruleCount() -> TestResult {
        let start = ContinuousClock.now
        let raw = """
        # Rules
        ## Always
        - a
        * b
        ## Learned
        ### Git
        - c
          - c.1
        ```
        - not a rule
        ```
        -not a bullet
        ### Docs
        + d
        """
        let count = BarrackOverview.countRules(raw)
        return .make("OV-02a", "Info 규칙 수 = RULES.md 전체 항목(하위 섹션 포함, 코드 블록 제외)",
                     status: count == 5 ? .pass : .fail, cause: .app,
                     evidence: ["count": "\(count)", "expected": "5"], startedAt: start)
    }

    /// IN-09c: which keys the focused terminal takes before the menus.
    private func terminalOwnsControlKeys() -> TestResult {
        let start = ContinuousClock.now
        let cases: [(String, NSEvent.ModifierFlags, String, Bool)] = [
            ("⌃C", [.control], "c", true), ("⌃⇧C", [.control, .shift], "C", true),
            ("⌃C+capslock", [.control, .capsLock], "c", true), ("fn⌃C", [.control, .function], "c", false),
            ("⌘C", [.command], "c", false), ("⌃⌘F", [.control, .command], "f", false),
            ("⌃⌥C", [.control, .option], "c", false), ("⌃1", [.control], "1", false),
            ("⌃/", [.control], "/", false), ("c", [], "c", false), ("⌃ㅊ", [.control], "ㅊ", false),
        ]
        let wrong = cases.filter { ProbeTerminalView.ownsControlKey(flags: $0.1, characters: $0.2) != $0.3 }.map(\.0)
        return .make("IN-09c", "터미널이 메뉴보다 먼저 받는 키: ⌃·⌃⇧+영문자만 (fn·⌥·⌘ 조합은 메뉴로)",
                     status: wrong.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["cases": "\(cases.count)", "wrong": wrong.joined(separator: ",")], startedAt: start)
    }

    private func processTree() -> TestResult {
        let start = ContinuousClock.now
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["2"]
        try? child.run()
        defer { child.terminate() }
        let mine = ProcessInfo.processInfo.processIdentifier
        let descendant = ProcessTree.isDescendant(child.processIdentifier, of: mine)
        let unrelated = ProcessTree.isDescendant(mine, of: child.processIdentifier)
        let ok = descendant && !unrelated
        return .make("AT-01b", "pane 매칭용 프로세스 트리: 자식은 후손, 부모는 아님",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["child_is_descendant": "\(descendant)", "parent_is_descendant": "\(unrelated)"],
                     startedAt: start)
    }

    /// Real aib v1.6.0 output shapes (ANSI colors included).
    private func maintenanceParsing() -> TestResult {
        let start = ContinuousClock.now
        let clean = "\u{1B}[0;36m[INFO]\u{1B}[0m [dry-run] Would delete: sessions/claude-x.md\n\u{1B}[0;36m[INFO]\u{1B}[0m Would clean 1 empty session(s)"
        let lint = "  \u{1B}[0;33m[STALE]\u{1B}[0m wiki/topics/A.md: 2026-05-04\n\n\u{1B}[0;33m[WARN]\u{1B}[0m Wiki lint: 101 issue(s) found"
        let ok = "\u{1B}[0;32m[OK]\u{1B}[0m   Skills wiring is in sync"
        let quiet = MaintenanceScanner.parse(verify: "", clean: "", gc: "", lint: "", skills: ok,
                                             cliVersion: "aib v1.6.0", barrackVersion: "1.6.0", path: "/b")
        let busy = MaintenanceScanner.parse(verify: "claude-1 changed after seal", clean: clean, gc: "", lint: lint,
                                            skills: ok, cliVersion: "aib v1.6.0", barrackVersion: "1.5.0", path: "/b")
        let kinds = busy.map(\.kind)
        let counts = Dictionary(uniqueKeysWithValues: busy.map { ($0.kind, $0.count) })
        let pass = quiet.isEmpty && kinds == [.seal, .clean, .wikiLint, .versionDrift]
            && counts[.clean] == 1 && counts[.wikiLint] == 101
            && busy.first { $0.kind == .clean }?.command.contains("--dry-run && printf") == true
        return .make("MT-01a", "정비 항목 해석(aib 출력, 색 코드 포함)·적용 전 dry-run",
                     status: pass ? .pass : .fail, cause: .app,
                     evidence: ["quiet": "\(quiet.count)", "kinds": kinds.map(\.rawValue).joined(separator: ","),
                                "counts": counts.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ",")],
                     startedAt: start)
    }

    /// Daemon by default, but a self-test never lands on the user's socket.
    private func socketChoice() -> TestResult {
        let start = ContinuousClock.now
        let user = DaemonBackend.socketPath(for: ["app"]) ?? "nil"
        let test = DaemonBackend.socketPath(for: ["app", "--selftest"]) ?? "nil"
        let only = DaemonBackend.socketPath(for: ["app", "--selftest-only=input"]) ?? "nil"
        let explicit = DaemonBackend.socketPath(for: ["app", "--selftest", "--ptyd-socket=/tmp/x.sock"]) ?? "nil"
        let exec = DaemonBackend.socketPath(for: ["app", "--backend=exec"])
        let ok = user.hasSuffix("/ptyd-v1.sock") && test.hasSuffix("/ptyd-selftest.sock") && only == test
            && explicit == "/tmp/x.sock" && exec == nil
        return .make("DB-01a", "데몬 기본값·버전 소켓, self-test는 전용 소켓, --backend=exec는 데몬 없음",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["user": user, "selftest": test, "exec": exec ?? "nil"], startedAt: start)
    }

    private func skillsAndCouncil() -> TestResult {
        let start = ContinuousClock.now
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-sk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent("skills/council")
        let minutes = root.appendingPathComponent("resources/council")
        try? FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: minutes, withIntermediateDirectories: true)
        try? "---\nname: council\ndescription: \"Debate\"\n---\n# Body".write(
            to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try? "# m".write(to: minutes.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try? "# p".write(to: minutes.appendingPathComponent("a-prompt.md"), atomically: true, encoding: .utf8)
        let skills = BarrackDocuments.skills(in: root).map { $0.deletingLastPathComponent().lastPathComponent }
        let council = BarrackDocuments.councilMinutes(in: root).map(\.lastPathComponent)
        let header = BarrackDocuments.frontmatterAsHeader("---\nname: council\ndescription: \"Debate\"\n---\n# Body")
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9, minute: 5))!
        let command = CouncilCommand.make(topic: "REST 'vs' gRPC", rounds: 2, now: date)
        let ok = skills == ["council"] && council == ["a.md"] && header == "> **council** — Debate\n\n# Body"
            && command == "mkdir -p resources/council && aib council -r 2 -o resources/council/20261102-0905-council.md 'REST '\\''vs'\\'' gRPC'"
        return .make("SK-01a", "Skills·Council 문서 찾기, SKILL.md 머리글 표시, council 명령(-o, 따옴표)",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["skills": skills.joined(separator: ","), "council": council.joined(separator: ","),
                                "header": header, "command": command], startedAt: start)
    }

    private func editingPolicy() -> TestResult {
        let start = ContinuousClock.now
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-ed-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("wiki"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = { (name: String, body: String) -> URL in
            let url = root.appendingPathComponent(name)
            try? body.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let rules = file("RULES.md", "# Rules")
        let soul = file("SOUL.md", "# Soul")
        let sessions = file("SESSIONS.md", "<!-- AIB:OWNERSHIP — [SYSTEM] x -->\n# S")
        let wiki = file("wiki/Index.md", "# Wiki")
        let editable = { (url: URL, destination: Destination) in DocumentEditing.isEditable(url, in: root, destination: destination) }
        let ok = editable(rules, .rules) && editable(soul, .rules) && !editable(sessions, .rules)
            && !editable(wiki, .wiki) && !editable(rules, .wiki)
        return .make("ED-01a", "편집 허용: 규칙 목적지의 USER-OWNED·AUTO-GROW만, Wiki·SYSTEM·RECORD는 읽기 전용",
                     status: ok ? .pass : .fail, cause: .app, startedAt: start)
    }

    /// An agent appended to RULES.md while the user edited: never clobber.
    private func editingConflict() -> TestResult {
        let start = ContinuousClock.now
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-ed-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = "# Rules\n- a\n"
        try? original.write(to: url, atomically: true, encoding: .utf8)
        let unchanged = DocumentEditing.save(edited: original, original: original, to: url)
        let saved = DocumentEditing.save(edited: "# Rules\n- a\n- mine\n", original: original, to: url)
        let afterSave = try? String(contentsOf: url, encoding: .utf8)
        try? "# Rules\n- a\n- mine\n- agent\n".write(to: url, atomically: true, encoding: .utf8)
        let conflict = DocumentEditing.save(edited: "# Rules\n- a\n- mine2\n", original: "# Rules\n- a\n- mine\n", to: url)
        let kept = try? String(contentsOf: url, encoding: .utf8)
        let ok = unchanged == .unchanged && saved == .saved && afterSave == "# Rules\n- a\n- mine\n"
            && conflict == .conflict && kept == "# Rules\n- a\n- mine\n- agent\n"
        return .make("ED-01b", "저장: 바뀐 게 없으면 쓰지 않음, 편집 중 외부 변경은 충돌로 멈춤(덮어쓰지 않음)",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["unchanged": "\(unchanged)", "saved": "\(saved)", "conflict": "\(conflict)"],
                     startedAt: start)
    }

    /// Same rules as CC v1.6.1 sessions.rs (fields, sections, client).
    private func sessionParsing() -> TestResult {
        let start = ContinuousClock.now
        let text = """
        # Session: claude-1
        - **Client**: Claude Code
        - **Started**: 2026-11-01 07:40
        - **Ended**: (active)
        - **Status**: active
        - **Task**: 패리티 플랜
        - **Continues**: claude-0
        ## Log
        <!-- Format hint -->
        - [07:45] a
        - [08:00] b
        ## Decisions
        - d1
        ## Blockers
        """
        let record = SessionRecords.record(id: "claude-1", text: text)
        let log = SessionRecords.section("Log", in: text)
        let ok = record.client == "Claude Code" && record.status == "active" && record.task == "패리티 플랜"
            && record.continues == "claude-0" && log == ["[07:45] a", "[08:00] b"]
            && SessionRecords.section("Decisions", in: text) == ["d1"] && SessionRecords.section("Blockers", in: text).isEmpty
            && SessionRecords.record(id: "codex-9", text: "").client == "Codex CLI"
            && SessionRecords.record(id: "x", text: "").client == "Unknown" && record.clientKey == "claude"
        return .make("SR-01a", "세션 기록 해석 = v1 규칙(필드·섹션·주석 제외·클라이언트 추정)",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["log": log.joined(separator: "|"), "client": record.client], startedAt: start)
    }

    /// v1 seal tests: intact, modified, unsealed, and the invalid cases.
    private func sealStatuses() -> TestResult {
        let start = ContinuousClock.now
        let body = Data("- **Status**: completed\n## Log\n- [10:00] work\n".utf8)
        let hex = { (data: Data) in SHA256Hex.of(data) }
        let line = "\(hex(body))  sessions/s1.md\n"
        let cases: [(SessionRecords.SealRead, Data, Bool, SessionDetail.Seal)] = [
            (.record(line), body, false, .intact),
            (.record(line), Data("changed".utf8), false, .modified),
            (.missing, body, false, .unsealed),
            (.unusable, body, false, .invalid),
            (.record("nothex  sessions/s1.md"), body, false, .invalid),
            (.record("\(hex(body))  sessions/other.md"), body, false, .invalid),
            (.record(line), body, true, .invalid),
        ]
        let failures = cases.enumerated().compactMap { index, item -> String? in
            let got = SessionRecords.sealStatus(item.0, id: "s1", bytes: item.1, isSymlink: item.2)
            return got == item.3 ? nil : "#\(index) \(got.rawValue)"
        }
        // A symlinked .seals directory is unusable, not missing.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-seal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: root.appendingPathComponent("sessions/.seals"),
                                                    withDestinationURL: root.appendingPathComponent("real"))
        let symlinked = SessionRecords.readSeal(barrack: root, id: "s1")
        let ok = failures.isEmpty && symlinked == .unusable
        return .make("SR-01b", "봉인 검증 = aib sessions verify(무결·변경·미봉인·무효, 심볼릭 링크 거부)",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: ","), "symlinked_dir": "\(symlinked)"], startedAt: start)
    }

    private func sessionCommands() -> TestResult {
        let start = ContinuousClock.now
        let resume = SessionRecords.continueCommand(client: "codex", sessionID: "claude-1")
        let expected = "aib start codex '이전 세션 claude-1의 작업을 이어서 진행해주세요. sessions/claude-1.md 파일을 읽고 작업을 계속하세요.'"
        let monitor = SessionRecords.monitorCommand(sessionID: "claude-1")
        let ok = resume == expected && monitor.contains("tail -30 'sessions/claude-1.md'") && monitor.contains("sleep 3")
        return .make("SR-01c", "Continue 명령 = v1 프롬프트(aib start <대상>), Monitor = 3초 tail",
                     status: ok ? .pass : .fail, cause: .app, evidence: ["continue": resume], startedAt: start)
    }

    private func readerAppliesAck() -> TestResult {
        let start = ContinuousClock.now
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-lv-\(UUID().uuidString)")
        let live = root.appendingPathComponent("sessions/.live")
        try? FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Int(Date().timeIntervalSince1970)
        let status = { (id: String, state: String) in
            "{\"session_id\":\"\(id)\",\"run_id\":\"run-\(id)\",\"state\":\"\(state)\",\"ts\":\(now),\"pid\":0}"
        }
        try? status("a", "done").write(to: live.appendingPathComponent("a.status"), atomically: true, encoding: .utf8)
        try? status("b", "done").write(to: live.appendingPathComponent("b.status"), atomically: true, encoding: .utf8)
        try? "{\"acked_run_id\":\"run-b\",\"ack_ts\":\(now)}".write(
            to: live.appendingPathComponent("b.ack"), atomically: true, encoding: .utf8)
        let states = Dictionary(uniqueKeysWithValues: LivenessReader.read(barrackPath: root.path, now: now).map { ($0.id, $0.state) })
        let ok = states == ["a": .done, "b": .idle]
        return .make("LV-01b", "sidecar 읽기: ack가 맞으면 done → idle",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["states": states.map { "\($0.key)=\($0.value.rawValue)" }.sorted().joined(separator: ",")],
                     startedAt: start)
    }
}
