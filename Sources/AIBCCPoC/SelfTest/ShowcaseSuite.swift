import AppKit

/// Screenshots for the README (explicit suite `--selftest-only=showcase`):
/// realistic screens over the demo barracks from scripts/make-demo.sh, with
/// a real Claude Code idling at its prompt (nothing is sent). Refuses to run
/// unless the app reads the demo registry, so a user's own barracks never
/// end up in a picture. Needs scripts/capture-watcher.sh; then
/// scripts/showcase-compose.py copies the captures into docs/screenshots.
@MainActor
struct ShowcaseSuite {
    typealias Shoot = (String) async -> Void
    let harness: SelfTestHarness
    private var workspace: WorkspaceModel { harness.workspace }
    /// Agents, workspace and Files: room for four terminals beside the list.
    private static let wide = NSSize(width: 1600, height: 1000)
    private static let standard = NSSize(width: 1440, height: 900)
    private static let workingSession = "codex-20261103-1010"

    func run() async -> [TestResult] {
        let start = ContinuousClock.now
        guard AppConstants.Paths.barracksRegistry.contains("/aibcc-demo/"),
              let barrack = workspace.barracks.first(where: { $0.name == "web_service" }), let window = harness.window else {
            return [.make("SH-01", "README 스크린샷", status: .unverified,
                          evidence: ["reason": "run with AIB_REGISTRY=/tmp/aibcc-demo/barracks.json (scripts/make-demo.sh)"], startedAt: start)]
        }
        var shots: [String] = []
        let shoot: Shoot = { label in
            // A key window, as the user sees it (not the dimmed inactive look).
            NSApp.activate()
            harness.window?.makeKeyAndOrderFront(nil)
            await harness.pause(.milliseconds(300))
            if let url = await harness.requestCapture(label: "showcase-\(label)") { shots.append(url.lastPathComponent) }
        }
        workspace.selectedBarrackID = barrack.id
        await resize(window, to: Self.wide)
        await archiveOneOutput(in: barrack)
        let claude = await startTerminals(in: barrack, window: window)
        let working = await harness.waitUntil(.seconds(45)) { workspace.liveness.workingCount > 0 }
        await agentScenes(barrack, shoot)
        let attention = await attentionScene()
        await filesScene(barrack, shoot)
        await resize(window, to: Self.standard)
        await barrackScenes(barrack, shoot)
        await destinationScenes(barrack, shoot)
        await sheetScenes(shoot)
        let settings = await darkAndSettings(shoot)
        await updateScene(shoot)
        if let claude, let ctrlC = EventSynthesizer.control("c") {
            harness.focus(claude)
            EventSynthesizer.press(ctrlC, in: window)
            await harness.pause(.milliseconds(400))
            EventSynthesizer.press(ctrlC, in: window)
        }
        return [.make("SH-01", "README 스크린샷 \(shots.count)장 (데모 배럭)", status: .unverified,
                      evidence: ["captures": shots.joined(separator: ", "), "working": "\(working)",
                                 "attention": attention, "settings": settings], startedAt: start)]
    }

    /// A neutral prompt (no account or host name in the pictures) and none
    /// of the variables this run inherited from the Claude session driving it.
    static func demoShell(_ script: String) -> String {
        "/bin/zsh -fc " + AgentLauncher.shellQuote("\(unsetDriver); export PROMPT='%F{6}%1~%f %# '; " + script)
    }

    /// The driving session's variables (Claude's, aib's, tmux's: Claude Code
    /// prints a tmux hint when it sees TMUX).
    private static let unsetDriver = "unset -m 'CLAUDE*' MAP_SESSION_ID TMUX TMUX_PANE"
    /// Claude Code with no status line: the user's own would show their
    /// usage and machine in the picture.
    private static let claudeSettings = #"{"statusLine":{"type":"command","command":"true"}}"#

    private func resize(_ window: NSWindow, to size: NSSize) async {
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let width = min(size.width, screen.width), height = min(size.height, screen.height)
        window.setFrame(NSRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height), display: true)
        await harness.pause(.seconds(1))
    }

    private static let testRun = "printf '\\n> web_service@1.4.0 test\\n> vitest run\\n\\n ✓ src/checkout.test.ts (12)\\n ✓ src/orders.test.ts (31)\\n ✓ src/address.test.ts (8)\\n\\n Test Files  3 passed (3)\\n      Tests  51 passed (51)\\n   Duration  2.41s\\n\\n'"

    /// A finished test run, closed: it lands in the terminal output archive.
    private func archiveOneOutput(in barrack: Barrack) async {
        let pane = workspace.makePane(title: "npm test", command: Self.demoShell("cd \(barrack.path) && \(Self.testRun) && exec /bin/zsh -f"))
        await harness.install([pane], layout: .single)
        await harness.pause(.seconds(2))
        workspace.closePane(id: pane.id)
    }

    /// Four on screen — Claude Code at its prompt with a drafted request (not
    /// sent), aib on this barrack, a test run, the repository — and one held
    /// off screen whose aib session reports working (its pid, its task).
    private func startTerminals(in barrack: Barrack, window: NSWindow) async -> TerminalPane? {
        let path = barrack.path
        let claudePath = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/claude")
        let hasClaude = FileManager.default.isExecutableFile(atPath: claudePath)
        let claude = hasClaude ? workspace.makePane(
            title: "claude · 결제 화면 개편",
            command: "/bin/zsh -lc " + AgentLauncher.shellQuote("\(Self.unsetDriver); export DISABLE_AUTOUPDATER=1; cd \(path) && exec \(claudePath) --settings "
                + AgentLauncher.shellQuote(Self.claudeSettings)),
            agent: .claude) : nil
        let aib = workspace.makePane(title: "aib", command: Self.demoShell("cd \(path) && clear && \(Self.aibCommands) && exec /bin/zsh -f"))
        let tests = workspace.makePane(title: "npm test", command: Self.demoShell("cd \(path) && clear && \(Self.testRun) && exec /bin/zsh -f"))
        let log = "cd \(path) && clear && git log --oneline --graph --decorate -6 && echo && git status -sb && echo && exec /bin/zsh -f"
        let git = workspace.makePane(title: "git", command: Self.demoShell(log))
        let codex = workspace.makePane(title: "codex · 주문 API", command: Self.demoShell(Self.workingScript(path)), agent: .codex)
        await harness.install([claude, aib, tests, git, codex].compactMap { $0 }, layout: .quad)
        guard let claude else { return nil }
        harness.focus(claude)
        await harness.pause(.seconds(8))
        await passTrustPrompt(claude, window: window)
        // Word by word (the TUI drops keys that arrive in one burst); letters
        // and spaces only — EventSynthesizer.type drops punctuation.
        for word in "Draft the rollout plan for the checkout redesign and add an AB test section".split(separator: " ") {
            _ = EventSynthesizer.type(String(word) + " ", in: window)
            await harness.pause(.milliseconds(250))
        }
        await harness.pause(.seconds(2))
        return claude
    }

    /// Real aib commands on the barrack, each after a prompt-like line.
    /// (`aib status` is left out: aib 1.6.0 fails on it with no SESSIONS.md rows.)
    private static var aibCommands: String {
        let home = NSHomeDirectory()
        let path = "export PATH=\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let run = ["skills list", "sessions verify", "wiki lint"].map {
            "printf '\\033[36mweb_service\\033[0m %% aib \($0)\\n' && aib \($0) 2>&1; echo"
        }
        return ([path] + run).joined(separator: "; ")
    }

    /// First run in a folder asks whether to trust it; answer yes whichever
    /// option the cursor starts on.
    private func passTrustPrompt(_ claude: TerminalPane, window: NSWindow) async {
        let screen = claude.probeView?.readScreenText() ?? ""
        guard screen.localizedCaseInsensitiveContains("trust") else { return }
        let cursor = screen.split(separator: "\n").first { $0.contains("❯") } ?? ""
        if !cursor.contains("Yes") { EventSynthesizer.press(EventSynthesizer.downArrow, in: window) }
        await harness.pause(.milliseconds(300))
        EventSynthesizer.press(EventSynthesizer.returnKey, in: window)
        await harness.pause(.seconds(4))
    }

    /// Marks the demo Codex session working with this terminal's pid.
    private static func workingScript(_ path: String) -> String {
        let json = "{\"version\":1,\"session_id\":\"\(workingSession)\",\"run_id\":\"showcase-%d\",\"state\":\"working\",\"event\":\"demo\","
            + "\"reason\":\"demo\",\"source\":\"codex_hook\",\"confidence\":\"high\",\"comm\":\"codex\",\"cwd\":\"\(path)\",\"ts\":%d,\"pid\":%d}"
        return "cd \(path) && mkdir -p sessions/.live && printf '\(json)' $$ $(date +%s) $$ > sessions/.live/\(workingSession).status && exec sleep 1800"
    }

    private func agentScenes(_ barrack: Barrack, _ shoot: Shoot) async {
        workspace.destination = .sessions
        workspace.isArtifactPanelVisible = false
        await harness.pause(.seconds(3))
        await shoot("01-agents")
        workspace.setLayout(.double)
        workspace.isArtifactPanelVisible = true
        await harness.pause(.seconds(1))
        if let design = harness.artifacts.files.first(where: { $0.name == "checkout-redesign.md" }) { harness.artifacts.select(design) }
        await harness.pause(.seconds(2))
        await shoot("02-workspace")
    }

    /// The 주의 · 작업 중 list is a popover: capturing its window captures it
    /// over the main window (its parent).
    private func attentionScene() async -> String {
        guard let window = harness.window else { return "no window" }
        workspace.isAttentionListPresented = true
        await harness.pause(.seconds(1))
        let popover = NSApp.windows.first { $0 !== window && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        let url = await harness.requestCapture(label: "showcase-03-attention", of: popover ?? window)
        workspace.isAttentionListPresented = false
        await harness.pause(.milliseconds(600))
        return popover == nil ? "popover not found" : url == nil ? "capture failed" : "ok"
    }

    private func filesScene(_ barrack: Barrack, _ shoot: Shoot) async {
        workspace.destination = .files
        workspace.fileBrowser.open(barrack.url.appendingPathComponent("docs/design/checkout-redesign.md"), in: barrack)
        workspace.fileBrowser.setExpanded(barrack.url.appendingPathComponent("docs/meetings"), true, in: barrack)
        await harness.pause(.seconds(2))
        await shoot("04-files")
    }

    private func barrackScenes(_ barrack: Barrack, _ shoot: Shoot) async {
        workspace.destination = .barrack
        await harness.pause(.seconds(3))
        await shoot("05-barrack")
        workspace.destination = .sessions
        workspace.isPalettePresented = true
        await harness.pause(.seconds(1))
        if let window = harness.window { _ = EventSynthesizer.type("api", in: window) }
        await harness.pause(.seconds(2))
        await shoot("06-palette")
        workspace.isPalettePresented = false
        await harness.pause(.milliseconds(500))
    }

    private func destinationScenes(_ barrack: Barrack, _ shoot: Shoot) async {
        workspace.historyShowsArchive = false
        workspace.pendingSessionID = "claude-20261101-1015"
        workspace.destination = .history
        await harness.pause(.seconds(2))
        await shoot("07-history")
        // Only the demo run: the startup shell replaced at install is archived too.
        workspace.scrollback.list().filter { $0.title != "npm test" }.forEach { workspace.deleteArchived($0.id) }
        workspace.historyShowsArchive = true
        await harness.pause(.seconds(2))
        await shoot("08-terminal-archive")
        let documents: [(Destination, String, Bool, String)] = [
            (.rules, "RULES.md", true, "09-rules-list"), (.rules, "SOUL.md", true, "10-soul-form"),
            (.wiki, "wiki/topics/deploy-runbook.md", false, "11-wiki"), (.council, "resources/council/20261102-1410-council.md", false, "12-council"),
        ]
        for (destination, file, form, label) in documents {
            workspace.destination = destination
            await harness.pause(.milliseconds(600))
            workspace.pendingDocument = barrack.url.appendingPathComponent(file)
            workspace.pendingStructuredEdit = form
            await harness.pause(.seconds(2))
            await shoot(label)
            workspace.pendingStructuredEdit = false
        }
        await skillAndGitScenes(barrack, shoot)
    }

    private func skillAndGitScenes(_ barrack: Barrack, _ shoot: Shoot) async {
        workspace.destination = .skills
        await harness.pause(.milliseconds(600))
        workspace.pendingDocument = barrack.url.appendingPathComponent("skills/release-notes/SKILL.md")
        await harness.pause(.seconds(2))
        await shoot("13-skills")
        workspace.pendingStructuredEdit = true
        await harness.pause(.seconds(2))
        await shoot("14-skill-editor")
        workspace.pendingStructuredEdit = false
        workspace.destination = .git
        await harness.pause(.seconds(3))
        await shoot("15-git")
    }

    private func sheetScenes(_ shoot: Shoot) async {
        workspace.destination = .sessions
        await harness.pause(.seconds(1))
        workspace.isNewAgentSheetPresented = true
        await harness.pause(.seconds(1))
        await shoot("16-new-agent")
        workspace.isNewAgentSheetPresented = false
        await harness.pause(.milliseconds(600))
        workspace.isAddBarrackPresented = true
        await harness.pause(.seconds(1))
        await shoot("17-add-barrack")
        workspace.isAddBarrackPresented = false
        await harness.pause(.milliseconds(600))
    }

    /// 22: a newer release on offer in the sidebar, and the question asked
    /// before installing it (a made-up 2.3.0; nothing is downloaded).
    private func updateScene(_ shoot: Shoot) async {
        guard let version = ReleaseVersion("2.3.0"),
              let page = URL(string: "https://github.com/ai-barracks/ai-barracks-cc/releases") else { return }
        let release = ReleaseInfo(version: version, page: page, archive: page, checksums: page, notes: "")
        let updater = AppUpdater.shared
        workspace.destination = .sessions
        updater.offer(release)
        await harness.pause(.milliseconds(800))
        updater.confirming = release
        await harness.pause(.seconds(1))
        await shoot("22-update")
        updater.confirming = nil
        await harness.settleSheet(shown: false)
        updater.offer(nil)
    }

    private func darkAndSettings(_ shoot: Shoot) async -> String {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        workspace.destination = .sessions
        await harness.pause(.seconds(2))
        await shoot("18-workspace-dark")
        workspace.destination = .barrack
        await harness.pause(.seconds(2))
        await shoot("19-barrack-dark")
        workspace.destination = .sessions
        NSApp.appearance = nil
        await harness.pause(.seconds(1))
        NSApp.activate()
        // The app menu's ⌘, item (SwiftUI's Settings scene owns its action).
        let item = NSApp.mainMenu?.items.first?.submenu?.items.first { $0.keyEquivalent == "," }
        if let item, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        await harness.pause(.seconds(3))
        let describe = { (window: NSWindow) in
            "\(type(of: window))|\(window.identifier?.rawValue ?? "")|\(window.title)|\(Int(window.frame.width))x\(Int(window.frame.height))|\(window.isVisible)"
        }
        let windows = NSApp.windows.map(describe).joined(separator: "; ")
        // SwiftUI names the Settings scene's window; a sheet or the closed 주의
        // popover would capture as the main window (their parent).
        guard let settings = NSApp.windows.first(where: { $0.isVisible && ($0.identifier?.rawValue ?? "").contains("Settings") })
        else { return "not found: \(windows)" }
        // Tall enough to show every section, not just the first.
        let screen = (settings.screen ?? NSScreen.main)?.visibleFrame ?? settings.frame
        let height = min(screen.height, 1000)
        settings.setFrame(NSRect(x: settings.frame.minX, y: screen.maxY - height, width: max(settings.frame.width, 560), height: height), display: true)
        settings.makeKeyAndOrderFront(nil)
        await harness.pause(.milliseconds(800))
        let url = await harness.requestCapture(label: "showcase-20-settings", of: settings)
        // 21: the same window scrolled to its end — the shortcut sections.
        let scrolled = Self.scrollToEnd(settings.contentView)
        await harness.pause(.milliseconds(800))
        let shortcuts = scrolled ? await harness.requestCapture(label: "showcase-21-shortcuts", of: settings) : nil
        settings.close()
        return url == nil || shortcuts == nil ? "capture failed (scrolled \(scrolled)): \(windows)" : "ok: \(describe(settings))"
    }

    private static func scrollToEnd(_ view: NSView?) -> Bool {
        guard let view else { return false }
        if let scroll = view as? NSScrollView, let document = scroll.documentView,
           document.bounds.height > scroll.contentView.bounds.height {
            let end = document.isFlipped ? document.bounds.height - scroll.contentView.bounds.height : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
            scroll.reflectScrolledClipView(scroll.contentView)
            return true
        }
        return view.subviews.contains { scrollToEnd($0) }
    }
}
