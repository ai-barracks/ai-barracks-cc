import SwiftUI

/// Right-hand artifact viewer: recent `.md` outputs on top, rendered
/// document below. Separate from the fixed RULES/Wiki viewers.
struct ArtifactPanel: View {
    let store: ArtifactStore
    @State private var rendererFailure: String?

    var body: some View {
        VSplitView {
            fileList
                .frame(minHeight: 120, idealHeight: 200)
            documentView
                .frame(minHeight: 200)
        }
    }

    private var fileList: some View {
        List(selection: selectionBinding) {
            Section("최근 산출물") {
                ForEach(store.files) { file in
                    ArtifactRow(file: file).tag(file.url)
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if store.files.isEmpty {
                ContentUnavailableView("산출물 없음", systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    @ViewBuilder
    private var documentView: some View {
        if let error = store.loadError {
            ContentUnavailableView("열 수 없음", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if let content = store.content, let failure = rendererFailure {
            RawSourceView(source: content, reason: failure)
        } else if let content = store.content {
            MarkdownWebView(
                source: content,
                documentURL: store.selected?.url,
                revision: store.revision,
                onRendererFailure: { rendererFailure = $0 }
            )
        } else {
            ContentUnavailableView("문서를 선택하세요", systemImage: "doc.richtext")
        }
    }

    private var selectionBinding: Binding<URL?> {
        Binding(
            get: { store.selected?.url },
            set: { url in store.select(store.files.first { $0.url == url }) }
        )
    }
}

/// Plain-text fallback when the renderer cannot load or run (MD-02).
private struct RawSourceView: View {
    let source: String
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("렌더러 사용 불가 — 원문 표시 (\(reason))", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(8)
            ScrollView {
                Text(source)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }
}

private struct ArtifactRow: View {
    let file: ArtifactFile

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(file.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(file.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(file.modified, style: .relative)
                    .monospacedDigit()
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }
}
