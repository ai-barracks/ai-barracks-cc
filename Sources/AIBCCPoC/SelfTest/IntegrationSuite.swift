import AppKit
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
            await viewerClickAndScrollThenType(),
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

    /// MD-04b: click inside the rendered document and scroll it, then click
    /// back into the terminal — the first keystroke must reach the PTY.
    private func viewerClickAndScrollThenType() async -> TestResult {
        let start = ContinuousClock.now
        guard let window = harness.window, let rec = harness.makeRecorderPane(name: "md-click") else {
            return failure("MD-04b", "뷰어 클릭·스크롤 후 터미널 복귀", reason: "setup", start)
        }
        await harness.install([rec.pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { rec.log.isReady }
        guard let webView = findWebView(in: window.contentView),
              let terminalPoint = harness.windowPoint(row: 3, column: 2, in: rec.pane)
        else { return failure("MD-04b", "뷰어 클릭·스크롤 후 터미널 복귀", reason: "web view or geometry", start) }
        let viewerPoint = webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
        EventSynthesizer.click(at: viewerPoint, count: 1, in: window)
        await harness.drain()
        let viewerFocused = harness.isFirstResponder(webView)
        _ = try? await webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight)")
        EventSynthesizer.click(at: terminalPoint, count: 1, in: window)
        await harness.drain()
        let mark = rec.log.mark()
        EventSynthesizer.type("x", in: window)
        let bytes = await harness.settledBytes(rec.log, since: mark)
        let ok = viewerFocused && bytes == [0x78]
        return .make("MD-04b", "뷰어 클릭·스크롤 후 터미널 클릭 복귀 첫 글자 유실 0",
                     status: ok ? .pass : .fail, cause: .app,
                     evidence: ["viewer_focused_by_click": "\(viewerFocused)", "hex": Hex.string(bytes)],
                     startedAt: start)
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

    private func findWebView(in view: NSView?) -> WKWebView? {
        guard let view else { return nil }
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { findWebView(in: $0) }.first
    }

    private func failure(_ id: String, _ title: String, reason: String, _ start: ContinuousClock.Instant) -> TestResult {
        .make(id, title, status: .fail, cause: .app, evidence: ["reason": reason], startedAt: start)
    }
}
