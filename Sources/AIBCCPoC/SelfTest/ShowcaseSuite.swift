import AppKit

/// Screenshots for the README (explicit suite `--selftest-only=showcase`):
/// realistic screens over the demo barracks from scripts/make-demo.sh, with
/// a real Claude Code idling at its prompt (nothing is sent). Refuses to run
/// unless the app reads the demo registry, so a user's own barracks never
/// end up in a picture. Needs scripts/capture-watcher.sh.
@MainActor
struct ShowcaseSuite {
    let harness: SelfTestHarness
    private var workspace: WorkspaceModel { harness.workspace }

    func run() async -> [TestResult] {
        let start = ContinuousClock.now
        guard AppConstants.Paths.barracksRegistry.contains("/aibcc-demo/"),
              let barrack = workspace.barracks.first(where: { $0.name == "web_service" }), let window = harness.window else {
            return [.make("SH-01", "README 스크린샷", status: .unverified,
                          evidence: ["reason": "run with AIB_REGISTRY=/tmp/aibcc-demo/barracks.json (scripts/make-demo.sh)"], startedAt: start)]
        }
        var shots: [String] = []
        let shoot = { (label: String) async in
            // A key window, as the user sees it (not the dimmed inactive look).
            NSApp.activate()
            harness.window?.makeKeyAndOrderFront(nil)
            await harness.pause(.milliseconds(300))
            if let url = await harness.requestCapture(label: "showcase-\(label)") { shots.append(url.lastPathComponent) }
        }
        workspace.selectedBarrackID = barrack.id
        workspace.isArtifactPanelVisible = true
        await archiveOneOutput(in: barrack)
        let claude = await startTerminals(in: barrack, window: window)
        await workspaceScene(barrack, shoot)
        await destinationScenes(barrack, shoot)
        await sheetScenes(window, shoot)
        let settings = await lightAndSettings(shoot)
        if let claude, let ctrlC = EventSynthesizer.control("c") {
            harness.focus(claude)
            EventSynthesizer.press(ctrlC, in: window)
            await harness.pause(.milliseconds(400))
            EventSynthesizer.press(ctrlC, in: window)
        }
        return [.make("SH-01", "README 스크린샷 \(shots.count)장 (데모 배럭)", status: .unverified,
                      evidence: ["captures": shots.joined(separator: ", "), "settings": settings], startedAt: start)]
    }

    /// A neutral prompt (no account or host name in the pictures) and none
    /// of the variables this run inherited from the Claude session driving it.
    static func demoShell(_ script: String) -> String {
        "/bin/zsh -fc " + AgentLauncher.shellQuote("unset -m 'CLAUDE*' MAP_SESSION_ID; export PROMPT='%F{6}%1~%f %# '; " + script)
    }

    /// A finished test run, closed: it lands in the terminal output archive.
    private func archiveOneOutput(in barrack: Barrack) async {
        let script = "cd \(barrack.path) && printf '\\n> web_service@1.4.0 test\\n> vitest run\\n\\n ✓ src/checkout.test.ts (12)\\n ✓ src/orders.test.ts (31)\\n ✓ src/address.test.ts (8)\\n\\n Test Files  3 passed (3)\\n      Tests  51 passed (51)\\n   Duration  2.41s\\n\\n' && exec /bin/zsh -f"
        let pane = workspace.makePane(title: "npm test", command: Self.demoShell(script))
        await harness.install([pane], layout: .single)
        await harness.pause(.seconds(2))
        workspace.closePane(id: pane.id)
    }

    /// Left: Claude Code at its prompt with a drafted request (not sent).
    /// Right: the repository's recent history.
    private func startTerminals(in barrack: Barrack, window: NSWindow) async -> TerminalPane? {
        let claudePath = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/claude")
        let log = "cd \(barrack.path) && clear && git log --oneline --graph --decorate -6 && echo && git status -sb && echo && exec /bin/zsh -f"
        let shell = workspace.makePane(title: "git", command: Self.demoShell(log))
        guard FileManager.default.isExecutableFile(atPath: claudePath) else {
            await harness.install([shell], layout: .single)
            return nil
        }
        let claude = workspace.makePane(title: "claude · 결제 화면 개편",
                                        command: "/bin/zsh -lc " + AgentLauncher.shellQuote("unset -m 'CLAUDE*' MAP_SESSION_ID; cd \(barrack.path) && exec \(claudePath)"))
        await harness.install([claude, shell], layout: .double)
        harness.focus(claude)
        await harness.pause(.seconds(8))
        // First run in the folder: the trust prompt has "No, exit" selected.
        EventSynthesizer.press(EventSynthesizer.downArrow, in: window)
        await harness.pause(.milliseconds(300))
        EventSynthesizer.press(EventSynthesizer.returnKey, in: window)
        await harness.pause(.seconds(4))
        // Word by word (the TUI drops keys that arrive in one burst); letters
        // and spaces only — EventSynthesizer.type drops punctuation.
        for word in "Draft the rollout plan for the checkout redesign and add an AB test section".split(separator: " ") {
            _ = EventSynthesizer.type(String(word) + " ", in: window)
            await harness.pause(.milliseconds(250))
        }
        await harness.pause(.seconds(2))
        return claude
    }

    private func workspaceScene(_ barrack: Barrack, _ shoot: (String) async -> Void) async {
        workspace.destination = .sessions
        workspace.inspectorTab = .artifacts
        await harness.pause(.seconds(1))
        if let design = harness.artifacts.files.first(where: { $0.name == "checkout-redesign.md" }) { harness.artifacts.select(design) }
        await harness.pause(.seconds(2))
        await shoot("01-workspace")
        workspace.inspectorTab = .context
        await harness.pause(.seconds(2))
        await shoot("02-context")
        workspace.inspectorTab = .maintenance
        await harness.pause(.seconds(3))
        await shoot("03-maintenance")
        workspace.inspectorTab = .artifacts
        workspace.isPalettePresented = true
        await harness.pause(.seconds(1))
        if let window = harness.window { _ = EventSynthesizer.type("checkout", in: window) }
        await harness.pause(.seconds(2))
        await shoot("04-palette")
        workspace.isPalettePresented = false
        await harness.pause(.milliseconds(500))
    }

    private func destinationScenes(_ barrack: Barrack, _ shoot: (String) async -> Void) async {
        workspace.historyShowsArchive = false
        workspace.pendingSessionID = "claude-20261101-1015"
        workspace.destination = .history
        await harness.pause(.seconds(2))
        await shoot("05-history")
        // Only the demo run: the startup shell replaced at install is archived too.
        workspace.scrollback.list().filter { $0.title != "npm test" }.forEach { workspace.deleteArchived($0.id) }
        workspace.historyShowsArchive = true
        await harness.pause(.seconds(2))
        await shoot("06-terminal-archive")
        let documents: [(Destination, String, Bool, String)] = [
            (.rules, "RULES.md", true, "07-rules-list"), (.rules, "SOUL.md", true, "08-soul-form"),
            (.wiki, "wiki/topics/deploy-runbook.md", false, "09-wiki"), (.council, "resources/council/20261102-1410-council.md", false, "10-council"),
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
        workspace.destination = .skills
        await harness.pause(.milliseconds(600))
        workspace.pendingDocument = barrack.url.appendingPathComponent("skills/release-notes/SKILL.md")
        await harness.pause(.seconds(2))
        await shoot("11-skills")
        workspace.pendingStructuredEdit = true
        await harness.pause(.seconds(2))
        await shoot("12-skill-editor")
        workspace.pendingStructuredEdit = false
        workspace.destination = .git
        await harness.pause(.seconds(3))
        await shoot("13-git")
    }

    private func sheetScenes(_ window: NSWindow, _ shoot: (String) async -> Void) async {
        workspace.destination = .sessions
        await harness.pause(.seconds(1))
        workspace.isNewAgentSheetPresented = true
        await harness.pause(.seconds(1))
        await shoot("14-new-agent")
        workspace.isNewAgentSheetPresented = false
        await harness.pause(.milliseconds(600))
        workspace.isAddBarrackPresented = true
        await harness.pause(.seconds(1))
        await shoot("15-add-barrack")
        workspace.isAddBarrackPresented = false
        await harness.pause(.milliseconds(600))
    }

    private func lightAndSettings(_ shoot: (String) async -> Void) async -> String {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        workspace.inspectorTab = .artifacts
        await harness.pause(.seconds(2))
        await shoot("16-workspace-dark")
        workspace.inspectorTab = .context
        await harness.pause(.seconds(2))
        await shoot("17-context-dark")
        NSApp.appearance = nil
        await harness.pause(.seconds(1))
        NSApp.activate()
        // The app menu's ⌘, item (SwiftUI's Settings scene owns its action).
        let item = NSApp.mainMenu?.items.first?.submenu?.items.first { $0.keyEquivalent == "," }
        if let item, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        await harness.pause(.seconds(3))
        let windows = NSApp.windows.map { "\(type(of: $0))|\($0.title)|\(Int($0.frame.width))x\(Int($0.frame.height))|\($0.isVisible)" }
            .joined(separator: "; ")
        // The Settings scene's window has no title; skip the menu bar extra.
        guard let settings = NSApp.windows.first(where: { $0 !== harness.window && $0.isVisible && $0.frame.width > 300
            && $0.frame.height > 200 && !String(describing: type(of: $0)).contains("StatusBar") && $0.title != "Item-0" })
        else { return "not found: \(windows)" }
        settings.makeKeyAndOrderFront(nil)
        await harness.pause(.milliseconds(500))
        let url = await harness.requestCapture(label: "showcase-18-settings", of: settings)
        settings.close()
        return url == nil ? "capture failed: \(windows)" : "ok"
    }
}
