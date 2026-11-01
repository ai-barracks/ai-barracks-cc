import SwiftUI

/// Fixed barrack documents (spec: rules and Wiki keep dedicated viewers,
/// separate from the artifact viewer). Read-only in M1; editing of
/// allowlisted files follows in M2.
struct DocumentView: View {
    let barrack: Barrack
    let destination: Destination
    @State private var selection: URL?
    @State private var source: String?
    @State private var failure: String?

    var body: some View {
        HStack(spacing: 0) {
            List(documents, id: \.self, selection: $selection) { file in
                Text(title(of: file)).font(Tokens.Font.body).lineLimit(1)
            }
            .listStyle(.sidebar)
            .frame(width: AppConstants.Documents.listWidth)
            Divider()
            reader
        }
        .background(Tokens.work)
        .onAppear { selection = selection ?? documents.first }
        .onChange(of: destination) { selection = documents.first }
        .onChange(of: barrack.id) { selection = documents.first }
        .onChange(of: selection, initial: true) { load() }
    }

    @ViewBuilder
    private var reader: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let file = selection, let ownership = Ownership.of(file, in: barrack.url) {
                OwnershipSeal(ownership: ownership)
                    .padding(Tokens.Spacing.m)
            }
            if let source, let failure {
                RawSourceView(source: source, reason: failure)
            } else if let source {
                MarkdownWebView(source: source, documentURL: selection, revision: source.hashValue,
                                onRendererFailure: { failure = $0 })
            } else {
                ContentUnavailableView("문서 없음", systemImage: "doc")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var documents: [URL] {
        let root = barrack.url
        switch destination {
        case .rules:
            return AppConstants.Documents.ruleFiles.map { root.appendingPathComponent($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        case .wiki:
            let topics = (try? FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("wiki/topics"), includingPropertiesForKeys: nil)) ?? []
            let index = root.appendingPathComponent("wiki/Index.md")
            return [index].filter { FileManager.default.fileExists(atPath: $0.path) }
                + topics.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        case .sessions:
            return []
        }
    }

    private func title(of file: URL) -> String {
        file.deletingPathExtension().lastPathComponent
    }

    private func load() {
        failure = nil
        guard let file = selection, let text = try? String(contentsOf: file, encoding: .utf8) else {
            source = nil
            return
        }
        // YAML is shown as a fenced block; the renderer handles Markdown.
        source = file.pathExtension == "md" ? text : "```yaml\n" + text + "\n```"
    }
}
