import SwiftUI

/// Fixed barrack documents (spec: rules and Wiki keep dedicated viewers,
/// separate from the artifact viewer): rules (raw and form editing), Wiki,
/// Council minutes. Skills have their own view (SkillsView).
struct DocumentView: View {
    let barrack: Barrack
    let destination: Destination
    var startCouncil: () -> Void = {}
    /// Bumped on any file event in the barrack (v1 file-changed refresh).
    var changes = 0
    /// A document ⌘K asked for; taken once, then cleared.
    @Binding var pending: URL?
    /// Asks for the form editor of the selected document; taken once.
    @Binding var pendingEdit: Bool
    @State private var selection: URL?
    @State private var source: String?
    @State private var failure: String?
    @State private var original: String?
    /// The file `original` was read from (selection can run ahead of it).
    @State private var loadedFile: URL?
    @State private var draft = ""
    @State private var isEditing = false
    @State private var isListEditing = false
    @State private var conflict = false
    /// The form's changes while its save is pending a conflict decision.
    @State private var structuredPatch: StructuredPatch?
    @State private var saveError: String?
    /// A file picked in the list while an edit was open (asks first).
    @State private var leaveTarget: URL?
    /// `aib sync --dry-run` after a save, when it objected (v1 FilesTab).
    @State private var validation: String?
    var validate: AibSync.Runner = AibSync.check

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
        default:
            ContentUnavailableView("문서 없음", systemImage: destination.symbol)
        }
    }

    private var browser: some View {
        HStack(spacing: 0) {
            List(documents, id: \.self, selection: guardedSelection) { file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(of: file)).font(Tokens.Font.body).lineLimit(1)
                    if destination == .rules, let role = BarrackDocuments.role(of: file.lastPathComponent) {
                        Text(role).font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary).lineLimit(2)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: AppConstants.Documents.listWidth)
            Divider()
            reader
        }
        .background(Tokens.work)
        .onAppear { selection = takePending() ?? selection ?? documents.first }
        .onChange(of: destination) { selection = takePending() ?? documents.first }
        .onChange(of: barrack.id) { selection = takePending() ?? documents.first }
        .onChange(of: pending) { if let next = takePending() { selection = next } }
        .onChange(of: selection, initial: true) { load() }
        .onChange(of: changes) { if !isEditing && !isListEditing { load() } }
        .onChange(of: pendingEdit) { takePendingEdit() }
        .alert("편집 중입니다", isPresented: Binding(get: { leaveTarget != nil }, set: { if !$0 { leaveTarget = nil } })) {
            Button("편집 버리고 이동", role: .destructive) {
                isEditing = false
                isListEditing = false
                selection = leaveTarget
                leaveTarget = nil
            }
            Button("계속 편집", role: .cancel) { leaveTarget = nil }
        } message: {
            Text("저장하지 않은 편집이 있을 수 있습니다(v1과 같이 이동 전에 묻습니다).")
        }
    }

    /// Picking another file while editing asks first instead of dropping
    /// the edit (v1 FilesTab confirm).
    private var guardedSelection: Binding<URL?> {
        Binding(get: { selection }, set: { next in
            guard next != selection else { return }
            if isEditing && draft != original || isListEditing {
                leaveTarget = next
            } else {
                selection = next
            }
        })
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
            if isListEditing, let original, let file = loadedFile, file == selection, let kind = StructuredKind(file: file) {
                // Identity = file + text it was opened on: the form's state
                // must never carry over from another file or an older text.
                kind.editor(original: original, onSave: { saveStructured($0) }, onCancel: cancelStructured)
                    .id([file.absoluteString, original])
            } else if isEditing {
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
            if structuredPatch != nil {
                Button("내 변경만 새 내용에 적용") { rebase() }
            }
            Button("내 편집으로 덮어쓰기", role: .destructive) {
                if let file = selection { finish(DocumentEditing.overwrite(edited: draft, to: file)) }
            }
            Button("다시 불러오기(내 편집 버림)") { isEditing = false; load() }
            Button("계속 편집", role: .cancel) {}
        } message: {
            Text(structuredPatch == nil ? "편집하는 동안 다른 곳(에이전트 등)이 이 파일을 고쳤습니다."
                 : "편집하는 동안 다른 곳(에이전트 등)이 이 파일을 고쳤습니다. 내가 바꾼 섹션만 새 내용에 적용하면 다른 곳의 변경도 남습니다.")
        }
    }

    @ViewBuilder
    private var editControls: some View {
        if let file = selection, DocumentEditing.isEditable(file, in: barrack.url, destination: destination) {
            if isEditing {
                if let saveError { Text(saveError).font(Tokens.Font.meta).foregroundStyle(Tokens.red) }
                Button("취소") { isEditing = false; saveError = nil }
                Button("저장") { save() }.keyboardShortcut("s", modifiers: .command)
            } else if isListEditing {
                if let saveError { Text(saveError).font(Tokens.Font.meta).foregroundStyle(Tokens.red).lineLimit(2) }
            } else {
                if let validation { Text(validation).font(Tokens.Font.meta).foregroundStyle(Tokens.orange).lineLimit(2) }
                let kind = StructuredKind(file: file)
                if let kind { Button(kind.editLabel) { isListEditing = true } }
                Button(kind == nil ? "편집" : "원문 편집") { draft = original ?? ""; isEditing = true }
            }
        }
    }

    private func save() {
        guard let file = selection, let original else { return }
        structuredPatch = nil
        let result = DocumentEditing.save(edited: draft, original: original, to: file)
        if result == .conflict { conflict = true } else { finish(result) }
    }

    /// The structured editor's output goes through the same conflict check.
    private func saveStructured(_ patch: @escaping StructuredPatch) {
        guard let file = selection, let original, case let .success(patched) = patch(original) else { return }
        draft = patched
        structuredPatch = patch
        saveError = nil
        let result = DocumentEditing.save(edited: patched, original: original, to: file)
        if result == .conflict { conflict = true } else { finish(result) }
    }

    private func runValidation() {
        validation = nil
        let barrackURL = barrack.url
        Task {
            if case let .failed(reason) = await validate(barrackURL) { validation = "저장됨 · aib sync --dry-run 경고: \(reason)" }
        }
    }

    private func cancelStructured() {
        isListEditing = false
        structuredPatch = nil
        saveError = nil
    }

    /// Re-applies the form's changes to the file as it is now.
    private func rebase() {
        guard let file = selection, let patch = structuredPatch,
              let current = try? String(contentsOf: file, encoding: .utf8) else { return }
        switch patch(current) {
        case let .success(rebased): finish(DocumentEditing.save(edited: rebased, original: current, to: file))
        case let .failure(failure): saveError = failure.message
        }
    }

    private func finish(_ result: DocumentEditing.SaveResult) {
        switch result {
        case .saved, .unchanged:
            if result == .saved, destination == .rules { runValidation() }
            structuredPatch = nil
            isListEditing = false
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
        case .council:
            return BarrackDocuments.councilMinutes(in: root)
        case .sessions, .history, .git, .skills:
            return []
        }
    }

    private func takePending() -> URL? {
        guard let wanted = pending, documents.contains(wanted) else { return nil }
        pending = nil
        return wanted
    }

    private func takePendingEdit() {
        guard pendingEdit, pending == nil, original != nil, let file = selection, loadedFile == file else { return }
        pendingEdit = false
        if StructuredKind(file: file) != nil, DocumentEditing.isEditable(file, in: barrack.url, destination: destination) {
            isListEditing = true
        }
    }

    private func title(of file: URL) -> String {
        file.deletingPathExtension().lastPathComponent
    }

    private func load() {
        failure = nil
        if loadedFile != selection { validation = nil }
        structuredPatch = nil
        saveError = nil
        isEditing = false
        isListEditing = false
        loadedFile = selection
        guard let file = selection, let text = try? String(contentsOf: file, encoding: .utf8) else {
            source = nil
            original = nil
            return
        }
        original = text
        // YAML is shown as a fenced block; the renderer handles Markdown.
        // A SKILL.md's frontmatter becomes a short header instead of raw YAML.
        source = file.pathExtension == "md" ? BarrackDocuments.frontmatterAsHeader(text) : "```yaml\n" + text + "\n```"
        takePendingEdit()
    }
}
