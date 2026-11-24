import AppKit
import SwiftUI
import WebKit

/// 3-column integration tests for the artifact viewer (MD-*).
@MainActor
struct IntegrationSuite {
    let harness: SelfTestHarness

    func run() async -> [TestResult] {
        let start = ContinuousClock.now
        guard let sandbox = makeSandbox() else {
            return [failure("MD-setup", "산출물 샌드박스 준비", reason: "temp dir", start)]
        }
        let store = harness.artifacts
        let original = harness.workspace.selectedBarrack?.url
        defer {
            store.watch(root: original)
            try? FileManager.default.removeItem(at: sandbox)
        }
        store.watch(root: sandbox)
        let results = [
            await listsRecentArtifacts(store, sandbox),
            await reloadsOnChange(store, sandbox),
            await renderCapture(),
            await terminalKeepsFirstKeystroke(),
            await viewerClickAndScrollThenType(sandbox: sandbox),
            await filesBrowser(),
            await filesEditSaves(),
        ]
        return results
    }

    // MARK: - Scenarios

    private func listsRecentArtifacts(_ store: ArtifactStore, _ sandbox: URL) async -> TestResult {
        let start = ContinuousClock.now
        let listed = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { store.files.count == 2 }
        let names = store.files.map(\.relativePath)
        let ok = listed && names == ["docs/newer.md", "older.md"]
        return .make("MD-01a", "최근 수정 .md 목록(시간순, 고정 뷰어 파일 제외)",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["listed": names.joined(separator: ", ")], startedAt: start)
    }

    private func reloadsOnChange(_ store: ArtifactStore, _ sandbox: URL) async -> TestResult {
        let start = ContinuousClock.now
        let target = sandbox.appendingPathComponent("older.md")
        store.select(store.files.first { $0.url.lastPathComponent == "older.md" })
        let before = store.revision
        let appended = (store.content ?? "") + "\n\n- 에이전트가 추가한 줄\n"
        try? appended.write(to: target, atomically: false, encoding: .utf8)
        let reloaded = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
            store.revision > before && (store.content?.contains("에이전트가 추가한 줄") ?? false)
        }
        return .make("MD-03a", "파일 변경 시 자동 새로고침 (스크롤 유지는 수동 확인)",
                     status: reloaded ? .pass : .fail, cause: .app,
                     evidence: ["revision_before": "\(before)", "revision_after": "\(store.revision)"],
                     startedAt: start)
    }

    /// MD-02 evidence: a composited capture of the rendered document (table,
    /// checklist) for visual review.
    private func renderCapture() async -> TestResult {
        let start = ContinuousClock.now
        await harness.pause(.milliseconds(500))
        let capture = await harness.requestCapture(label: "markdown-render")
        return .make("MD-02-cap", "GFM 렌더링 캡처 — 검토 필요", status: .unverified,
                     evidence: ["capture": capture?.lastPathComponent ?? "none"], startedAt: start)
    }

    /// MD-04: after the web view held focus, clicking back into the terminal
    /// must not drop the first keystroke.
    private func terminalKeepsFirstKeystroke() async -> TestResult {
        let start = ContinuousClock.now
        guard let window = harness.window, let rec = harness.makeRecorderPane(name: "md-focus") else {
            return failure("MD-04a", "뷰어 → 터미널 복귀 첫 글자", reason: "setup", start)
        }
        await harness.install([rec.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { rec.log.isReady }
        guard let webView = findWebView(in: window.contentView),
              let point = harness.windowPoint(row: 3, column: 2, in: rec.pane)
        else { return failure("MD-04a", "뷰어 → 터미널 복귀 첫 글자", reason: "web view or geometry", start) }
        window.makeFirstResponder(webView)
        let viewerHadFocus = harness.isFirstResponder(webView)
        EventSynthesizer.click(at: point, count: 1, in: window)
        await harness.drain()
        let terminalHasFocus = harness.isFirstResponder(rec.pane.probeView)
        let mark = rec.log.mark()
        EventSynthesizer.type("x", in: window)
        let bytes = await harness.settledBytes(rec.log, since: mark)
        let ok = viewerHadFocus && terminalHasFocus && bytes == [0x78]
        return .make("MD-04a", "뷰어 → 터미널 클릭 복귀 첫 글자 유실 0",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["viewer_had_focus": "\(viewerHadFocus)", "terminal_focus_after_click": "\(terminalHasFocus)",
                                "hex": Hex.string(bytes)],
                     startedAt: start)
    }

    /// MD-04b: click inside a long rendered document and scroll it with a real
    /// scroll-wheel event (scroll offset must change), then click back into
    /// the terminal — the first keystroke must reach the PTY (r3 #4).
    private func viewerClickAndScrollThenType(sandbox: URL) async -> TestResult {
        let start = ContinuousClock.now
        let title = "뷰어 클릭·실제 스크롤 후 터미널 클릭 복귀 첫 글자"
        guard let window = harness.window, let rec = harness.makeRecorderPane(name: "md-click") else {
            return failure("MD-04b", title, reason: "setup", start)
        }
        let store = harness.artifacts
        let longDoc = sandbox.appendingPathComponent("long.md")
        let body = "# 긴 문서\n\n" + (1...300).map { "- 줄 \($0)" }.joined(separator: "\n") + "\n"
        try? body.write(to: longDoc, atomically: true, encoding: .utf8)
        _ = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { store.files.contains { $0.url.lastPathComponent == "long.md" } }
        store.select(store.files.first { $0.url.lastPathComponent == "long.md" })
        await harness.install([rec.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { rec.log.isReady }
        await harness.pause(.milliseconds(600))
        guard let webView = findWebView(in: window.contentView),
              let terminalPoint = harness.windowPoint(row: 3, column: 2, in: rec.pane)
        else { return failure("MD-04b", title, reason: "web view or geometry", start) }
        let viewerPoint = webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
        EventSynthesizer.click(at: viewerPoint, count: 1, in: window)
        await harness.drain()
        let viewerFocused = harness.isFirstResponder(webView)
        let scrolled = await scrollWithWheel(webView)
        EventSynthesizer.click(at: terminalPoint, count: 1, in: window)
        await harness.drain()
        let mark = rec.log.mark()
        EventSynthesizer.type("x", in: window)
        let bytes = await harness.settledBytes(rec.log, since: mark)
        let ok = viewerFocused && scrolled > 0 && bytes == [0x78]
        return .make("MD-04b", title, status: ok ? .pass : .fail, cause: .app,
                     evidence: ["viewer_focused_by_click": "\(viewerFocused)",
                                "scroll_y_after_wheel": String(format: "%.0f", scrolled), "hex": Hex.string(bytes)],
                     startedAt: start)
    }

    /// Sends a pixel scroll-wheel event to the web view and returns scrollY
    /// (-1 when the offset cannot be read).
    private func scrollWithWheel(_ webView: WKWebView) async -> Double {
        if let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                 wheel1: -600, wheel2: 0, wheel3: 0),
           let event = NSEvent(cgEvent: cgEvent) {
            webView.scrollWheel(with: event)
        }
        await harness.pause(.milliseconds(400))
        let value = try? await webView.evaluateJavaScript("window.scrollY")
        return (value as? NSNumber)?.doubleValue ?? -1
    }

    // MARK: - Helpers

    private func makeSandbox() -> URL? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibcc-artifacts-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let wiki = root.appendingPathComponent("wiki", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: wiki, withIntermediateDirectories: true)
            try "# 위키 (고정 뷰어)\n".write(to: wiki.appendingPathComponent("Index.md"), atomically: true, encoding: .utf8)
            try "# 규칙 (고정 뷰어)\n".write(to: root.appendingPathComponent("RULES.md"), atomically: true, encoding: .utf8)
            let older = root.appendingPathComponent("older.md")
            try "# 오래된 산출물\n\n| a | b |\n|---|---|\n| 1 | 2 |\n".write(to: older, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: older.path)
            try "# 새 산출물\n\n- [x] 완료\n".write(to: docs.appendingPathComponent("newer.md"), atomically: true, encoding: .utf8)
            return root
        } catch {
            return nil
        }
    }

    /// FL-01b (2026-11-16 request): on Files, a Markdown file picked in the
    /// tree is rendered, a file inside folders opens with them expanded, a
    /// text file shows as written, and the screen is as it was left after a
    /// visit to Agents. Reads the selected barrack; writes nothing.
    private func filesBrowser() async -> TestResult {
        let start = ContinuousClock.now
        let title = "Files: 고른 md는 렌더, 폴더 안 파일은 폴더가 펼쳐진 채 열림, 텍스트는 원문, 다른 화면에 다녀와도 그대로"
        let workspace = harness.workspace
        guard let window = harness.window, let barrack = workspace.selectedBarrack else { return failure("FL-01b", title, reason: "setup", start) }
        let panelShown = workspace.isArtifactPanelVisible
        // Only the Files reader's web view may be on screen.
        workspace.isArtifactPanelVisible = false
        workspace.editInProgress = false
        workspace.destination = .files
        defer {
            workspace.isArtifactPanelVisible = panelShown
            workspace.destination = .sessions
        }
        let top = FileTree.children(of: barrack.url, showHidden: false)
        let nested = top.filter(\.isDirectory).lazy.flatMap { FileTree.children(of: $0.url, showHidden: false) }
            .first { !$0.isDirectory && FileTree.kind(of: $0.url) == .markdown }
        guard let markdown = top.first(where: { !$0.isDirectory && FileTree.kind(of: $0.url) == .markdown }) else {
            return .make("FL-01b", title, status: .unverified, evidence: ["reason": "no markdown file in the barrack"], startedAt: start)
        }
        var failures: [String] = []
        func rendered() async -> String {
            for _ in 0 ..< 60 {
                if let web = findWebView(in: window.contentView),
                   let text = try? await web.evaluateJavaScript("document.body.innerText") as? String,
                   text.trimmingCharacters(in: .whitespacesAndNewlines).count > 10 { return text }
                await harness.pause(.milliseconds(150))
            }
            return ""
        }
        workspace.fileBrowser.open(markdown.url, in: barrack)
        let first = await rendered()
        if first.isEmpty { failures.append("\(markdown.name) not rendered") }
        var nestedText = "none"
        if let nested {
            workspace.fileBrowser.open(nested.url, in: barrack)
            await harness.pause(.milliseconds(600))
            nestedText = await rendered()
            if nestedText.isEmpty { failures.append("\(nested.name) not rendered") }
            if !workspace.fileBrowser.state(of: barrack).expanded.contains(nested.url.deletingLastPathComponent().standardizedFileURL) {
                failures.append("folder of the opened file not expanded")
            }
        }
        if let text = top.first(where: { !$0.isDirectory && FileTree.kind(of: $0.url) == .text }),
           let written = try? String(contentsOf: text.url, encoding: .utf8), !written.isEmpty {
            workspace.fileBrowser.open(text.url, in: barrack)
            let shown = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) {
                findTextView(in: window.contentView, holding: written) != nil
            }
            if !shown { failures.append("\(text.name) not shown as text") }
            if findWebView(in: window.contentView) != nil { failures.append("web view left over a text file") }
        }
        workspace.fileBrowser.open(markdown.url, in: barrack)
        _ = await rendered()
        workspace.destination = .sessions
        await harness.pause(.milliseconds(500))
        workspace.destination = .files
        let back = await rendered()
        if back.isEmpty || workspace.fileBrowser.state(of: barrack).opened != markdown.url { failures.append("not restored after Agents") }
        return .make("FL-01b", title, status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | "), "markdown": markdown.name,
                                "rendered_chars": "\(first.count)", "nested": nested?.name ?? "none"], startedAt: start)
    }

    /// FL-01c: the reader's own editing, on a scratch folder (no barrack
    /// file is written), driven by its shortcuts: ⌘E opens the text as it
    /// is on disk, ⌘S writes what was typed and nothing before that, and a
    /// file aib keeps as a record cannot be edited.
    private func filesEditSaves() async -> TestResult {
        let start = ContinuousClock.now
        let title = "Files 편집: ⌘E → 입력 → ⌘S가 파일에 그대로 쓰이고(저장 전에는 안 씀), 기록 파일은 편집 불가"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-fl-edit-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("resources/note.md")
        let record = root.appendingPathComponent("sessions/s.md")
        for (file, text) in [(note, "# 처음\n\n본문\n"), (record, "# Session\n")] {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
        let barrack = Barrack(name: "fl-edit", path: root.path, description: nil)
        let reader = { (file: URL) in FileReaderView(barrack: barrack, file: file, isDirty: .constant(false)) }
        let host = NSHostingView(rootView: reader(note))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 720, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        var failures: [String] = []
        guard let edit = EventSynthesizer.command("e"), let save = EventSynthesizer.command("s") else {
            return failure("FL-01c", title, reason: "keys", start)
        }
        // The reader's shortcuts go to the key window.
        window.makeKeyAndOrderFront(nil)
        defer { harness.window?.makeKeyAndOrderFront(nil) }
        await harness.pause(.milliseconds(800))
        EventSynthesizer.press(edit, in: window)
        let original = "# 처음\n\n본문\n"
        let editorShown = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { editor(in: host)?.string == original }
        if !editorShown { failures.append("⌘E did not open the editor on the file's text (\(editor(in: host)?.string ?? "none"))") }
        let typed = "# 바뀜\n\n새 본문 with ``` and <b>\n"
        if let view = editor(in: host) {
            window.makeFirstResponder(view)
            view.insertText(typed, replacementRange: NSRange(location: 0, length: (view.string as NSString).length))
        }
        await harness.pause(.milliseconds(300))
        if (try? String(contentsOf: note, encoding: .utf8)) != original { failures.append("file written before saving") }
        EventSynthesizer.press(save, in: window)
        let saved = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { (try? String(contentsOf: note, encoding: .utf8)) == typed }
        if !saved { failures.append("saved text differs: \((try? String(contentsOf: note, encoding: .utf8)) ?? "unreadable")") }
        let closed = await harness.waitUntil(AppConstants.SelfTest.settleTimeout) { editor(in: host) == nil }
        if !closed { failures.append("editor stayed open after saving") }
        host.rootView = reader(record)
        await harness.pause(.milliseconds(800))
        EventSynthesizer.press(edit, in: window)
        await harness.pause(.milliseconds(800))
        if editor(in: host) != nil { failures.append("a session record can be edited") }
        if (try? String(contentsOf: record, encoding: .utf8)) != "# Session\n" { failures.append("record changed") }
        return .make("FL-01c", title, status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    private func editor(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let found = view as? NSTextView, found.isEditable { return found }
        return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }

    private func findTextView(in view: NSView?, holding text: String) -> NSTextView? {
        guard let view else { return nil }
        if let found = view as? NSTextView, !found.isEditable, found.string == text { return found }
        return view.subviews.lazy.compactMap { findTextView(in: $0, holding: text) }.first
    }

    private func findWebView(in view: NSView?) -> WKWebView? {
        guard let view else { return nil }
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { findWebView(in: $0) }.first
    }

    private func failure(_ id: String, _ title: String, reason: String, _ start: ContinuousClock.Instant) -> TestResult {
        .make(id, title, status: .fail, cause: .app, evidence: ["reason": reason], startedAt: start)
    }
}
