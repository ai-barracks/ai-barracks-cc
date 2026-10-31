import AppKit
import SwiftUI
import WebKit

/// Renders Markdown with the bundled micromark renderer (Renderer/dist).
/// Only the renderer bundle may load; link clicks open in the browser and
/// never navigate this view (MD-05). If the renderer cannot load or run, it
/// reports failure so the panel can fall back to plain source (MD-02).
struct MarkdownWebView: NSViewRepresentable {
    let source: String
    let documentURL: URL?
    let revision: Int
    let onRendererFailure: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFailure: onRendererFailure)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.loadRenderer(into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.show(source: source, documentURL: documentURL, revision: revision, in: webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private struct Pending {
            let source: String
            let keepScroll: Bool
        }

        private let onFailure: @MainActor (String) -> Void
        private var rendererDirectory: URL?
        private var isRendererLoaded = false
        private var pending: Pending?
        private var shownDocument: URL?
        private var shownRevision = -1
        private var readinessTimer: Task<Void, Never>?

        init(onFailure: @escaping @MainActor (String) -> Void) {
            self.onFailure = onFailure
        }

        func loadRenderer(into webView: WKWebView) {
            guard let directory = Bundle.main.resourceURL?
                .appendingPathComponent(AppConstants.Paths.rendererDirectory, isDirectory: true),
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(AppConstants.Paths.rendererEntry).path)
            else {
                onFailure("renderer bundle missing")
                return
            }
            rendererDirectory = directory.standardizedFileURL
            webView.loadFileURL(directory.appendingPathComponent(AppConstants.Paths.rendererEntry), allowingReadAccessTo: directory)
            readinessTimer = Task { [weak self] in
                try? await Task.sleep(for: AppConstants.Artifacts.rendererReadyTimeout)
                guard let self, !Task.isCancelled, !self.isRendererLoaded else { return }
                self.onFailure("renderer did not load in time")
            }
        }

        func show(source: String, documentURL: URL?, revision: Int, in webView: WKWebView) {
            guard revision != shownRevision || documentURL != shownDocument else { return }
            let next = Pending(source: source, keepScroll: documentURL == shownDocument)
            shownRevision = revision
            shownDocument = documentURL
            guard isRendererLoaded else {
                pending = next
                return
            }
            evaluate(next, in: webView)
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            isRendererLoaded = true
            readinessTimer?.cancel()
            if let next = pending {
                pending = nil
                evaluate(next, in: webView)
            }
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
            onFailure("navigation failed: \(error.localizedDescription)")
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: any Error) {
            onFailure("renderer load failed: \(error.localizedDescription)")
        }

        func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if action.navigationType == .linkActivated {
                openExternally(url)
                return .cancel
            }
            return isInsideRenderer(url) ? .allow : .cancel
        }

        private func evaluate(_ payload: Pending, in webView: WKWebView) {
            let body: [String: Any] = ["source": payload.source, "keepScroll": payload.keepScroll]
            guard let data = try? JSONSerialization.data(withJSONObject: body),
                  let json = String(data: data, encoding: .utf8)
            else {
                onFailure("could not encode document")
                return
            }
            webView.evaluateJavaScript("window.aibccShow(\(json))") { [weak self] _, error in
                guard let error else { return }
                MainActor.assumeIsolated { self?.onFailure("render script failed: \(error.localizedDescription)") }
            }
        }

        private func isInsideRenderer(_ url: URL) -> Bool {
            guard url.isFileURL, let rendererDirectory else { return false }
            return url.standardizedFileURL.path.hasPrefix(rendererDirectory.path)
        }

        private func openExternally(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
