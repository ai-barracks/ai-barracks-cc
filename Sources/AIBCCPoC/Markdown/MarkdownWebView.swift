import AppKit
import SwiftUI
import WebKit

/// Renders Markdown with the bundled micromark renderer (Renderer/dist).
/// Only the renderer bundle may load; link clicks open in the browser and
/// never navigate this view (MD-05).
struct MarkdownWebView: NSViewRepresentable {
    let source: String
    let documentURL: URL?
    let revision: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
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
        context.coordinator.show(
            source: source,
            documentURL: documentURL,
            revision: revision,
            in: webView
        )
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private struct Pending {
            let source: String
            let keepScroll: Bool
        }

        private var rendererDirectory: URL?
        private var isRendererLoaded = false
        private var pending: Pending?
        private var shownDocument: URL?
        private var shownRevision = -1

        func loadRenderer(into webView: WKWebView) {
            guard let directory = Bundle.main.resourceURL?
                .appendingPathComponent(AppConstants.Paths.rendererDirectory, isDirectory: true)
            else { return }
            rendererDirectory = directory.standardizedFileURL
            let entry = directory.appendingPathComponent(AppConstants.Paths.rendererEntry)
            webView.loadFileURL(entry, allowingReadAccessTo: directory)
        }

        func show(source: String, documentURL: URL?, revision: Int, in webView: WKWebView) {
            guard revision != shownRevision || documentURL != shownDocument else { return }
            let keepScroll = documentURL == shownDocument
            shownRevision = revision
            shownDocument = documentURL
            let next = Pending(source: source, keepScroll: keepScroll)
            guard isRendererLoaded else {
                pending = next
                return
            }
            evaluate(next, in: webView)
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            isRendererLoaded = true
            if let next = pending {
                pending = nil
                evaluate(next, in: webView)
            }
        }

        func webView(
            _: WKWebView,
            decidePolicyFor action: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
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
            else { return }
            webView.evaluateJavaScript("window.aibccShow(\(json))", completionHandler: nil)
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
