import SwiftUI

/// Fixed barrack documents (spec: rules and Wiki keep dedicated viewers,
/// separate from the artifact viewer). Read-only in M1; editing of
/// allowlisted files follows in M2.
struct DocumentView: View {
    let barrack: Barrack
    let destination: Destination
    var startCouncil: () -> Void = {}
    @State private var selection: URL?
    @State private var source: String?
    @State private var failure: String?
    @State private var original: String?
    @State private var draft = ""
    @State private var isEditing = false
    @State private var conflict = false
    @State private var saveError: String?

    var body: some View {
        if documents.isEmpty {
            emptyState
        } else {
            browser
        }
    }

    /// An empty destination says what it is for and how to fill it.
    @ViewBuilder
    private var emptyState: some View {
        switch destination {
        case .council:
            ContentUnavailableView {
                Label("Council 기록 없음", systemImage: destination.symbol)
            } description: {
                Text("Claude와 Codex가 토론한 결과가 resources/council에 쌓이면 여기서 읽습니다.")
            } actions: {
                Button("Council 시작 (⌘⇧C)", action: startCouncil)
            }
        case .skills:
            ContentUnavailableView("Skills 없음", systemImage: destination.symbol,
                                   description: Text("skills/<이름>/SKILL.md를 추가하면 여기서 읽습니다."))
        default:
            ContentUnavailableView("문서 없음", systemImage: destination.symbol)
        }
    }

    private var browser: some View {
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
            HStack {
                if let file = selection, let ownership = Ownership.of(file, in: barrack.url) {
                    OwnershipSeal(ownership: ownership)
                }
                Spacer()
                editControls
            }
            .padding(Tokens.Spacing.m)
            if isEditing {
                TextEditor(text: $draft)
                    .font(.system(size: 13).monospaced())
                    .padding(.horizontal, Tokens.Spacing.s)
            } else if let source, let failure {
                RawSourceView(source: source, reason: failure)
            } else if let source {
                MarkdownWebView(source: source, documentURL: selection, revision: source.hashValue,
                                onRendererFailure: { failure = $0 })
            } else {
                ContentUnavailableView("문서 없음", systemImage: "doc")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("파일이 바뀌었습니다", isPresented: $conflict) {
            Button("내 편집으로 덮어쓰기", role: .destructive) {
                if let file = selection { finish(DocumentEditing.overwrite(edited: draft, to: file)) }
            }
            Button("다시 불러오기(내 편집 버림)") { isEditing = false; load() }
            Button("계속 편집", role: .cancel) {}
        } message: {
            Text("편집하는 동안 다른 곳(에이전트 등)이 이 파일을 고쳤습니다.")
        }
    }

    @ViewBuilder
    private var editControls: some View {
        if let file = selection, DocumentEditing.isEditable(file, in: barrack.url, destination: destination) {
            if isEditing {
                if let saveError { Text(saveError).font(Tokens.Font.meta).foregroundStyle(Tokens.red) }
                Button("취소") { isEditing = false; saveError = nil }
                Button("저장") { save() }.keyboardShortcut("s", modifiers: .command)
            } else {
                Button("편집") { draft = original ?? ""; isEditing = true }
            }
        }
    }

    private func save() {
        guard let file = selection, let original else { return }
        let result = DocumentEditing.save(edited: draft, original: original, to: file)
        if result == .conflict { conflict = true } else { finish(result) }
    }

    private func finish(_ result: DocumentEditing.SaveResult) {
        switch result {
        case .saved, .unchanged:
            isEditing = false
            saveError = nil
            load()
        case .failed:
            saveError = "저장하지 못했습니다"
        case .conflict:
            conflict = true
        }
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
        case .skills:
            return BarrackDocuments.skills(in: root)
        case .council:
            return BarrackDocuments.councilMinutes(in: root)
        case .sessions, .history, .git:
            return []
        }
    }

    private func title(of file: URL) -> String {
        destination == .skills ? file.deletingLastPathComponent().lastPathComponent : file.deletingPathExtension().lastPathComponent
    }

    private func load() {
        failure = nil
        isEditing = false
        guard let file = selection, let text = try? String(contentsOf: file, encoding: .utf8) else {
            source = nil
            original = nil
            return
        }
        original = text
        // YAML is shown as a fenced block; the renderer handles Markdown.
        // A SKILL.md's frontmatter becomes a short header instead of raw YAML.
        source = file.pathExtension == "md" ? BarrackDocuments.frontmatterAsHeader(text) : "```yaml\n" + text + "\n```"
    }
}
