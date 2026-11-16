import AppKit
import PDFKit
import SwiftUI

/// The file picked in the Files tree: Markdown rendered, text as written,
/// an image or a PDF previewed; anything else names itself and offers
/// Finder. Markdown and text that aib does not manage can be edited, with
/// the same "the file changed under you" check as the rules editor.
struct FileReaderView: View {
    let barrack: Barrack
    let file: URL?
    /// Bumped when files changed or the user asked to refresh.
    var changes = 0
    @Binding var isDirty: Bool
    /// Tells the workspace an edit is open, so navigation elsewhere asks.
    var editInProgress: Binding<Bool> = .constant(false)
    /// Bumped when the user discarded edits to navigate (WorkspaceModel).
    var discardRevision = 0
    @State private var content: FileContent?
    @State private var loadedFile: URL?
    @State private var details = ""
    @State private var revision = 0
    @State private var rendererFailure: String?
    @State private var draft = ""
    @State private var isEditing = false
    @State private var conflict = false
    @State private var saveError: String?

    var body: some View {
        Group {
            if let file {
                VStack(alignment: .leading, spacing: 0) {
                    header(file)
                    Divider()
                    viewer(file)
                }
            } else {
                ContentUnavailableView("파일을 선택하세요", systemImage: "doc.text.magnifyingglass",
                                       description: Text("왼쪽에서 폴더를 열고 파일을 고르면 여기서 봅니다."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: file, initial: true) { isEditing = false; load() }
        .onChange(of: changes) { if !isEditing { load() } }
        .onChange(of: dirty, initial: true) {
            isDirty = dirty
            editInProgress.wrappedValue = dirty
        }
        .onChange(of: discardRevision) { isEditing = false }
        .onDisappear { editInProgress.wrappedValue = false }
        .alert("파일이 바뀌었습니다", isPresented: $conflict) {
            Button("내 편집으로 덮어쓰기", role: .destructive) {
                if let file { finish(DocumentEditing.overwrite(edited: draft, to: file)) }
            }
            Button("다시 불러오기(내 편집 버림)") { isEditing = false; load() }
            Button("계속 편집", role: .cancel) {}
        } message: {
            Text("편집하는 동안 다른 곳(에이전트 등)이 이 파일을 고쳤습니다.")
        }
    }

    /// The text as it is on disk, when the file is shown as text.
    private var original: String? {
        switch content {
        case let .markdown(text)?, let .text(text)?: text
        default: nil
        }
    }

    private var dirty: Bool { isEditing && draft != original }

    private func header(_ file: URL) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: FileTree.kind(of: file).symbol).foregroundStyle(Tokens.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.lastPathComponent).font(Tokens.Font.bodyMedium).lineLimit(1).truncationMode(.middle)
                    Text(details).font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary).lineLimit(1).truncationMode(.middle)
                }
                .help(FileTree.relativePath(of: file, under: barrack.url))
                Spacer(minLength: Tokens.Spacing.s)
                // AppKit controls do not shrink below their own width
                // (UX-02): say so, and let the name truncate instead.
                controls(file).fixedSize()
            }
            if let ownership = Ownership.of(file, in: barrack.url) { OwnershipSeal(ownership: ownership) }
        }
        .padding(Tokens.Spacing.m)
    }

    @ViewBuilder
    private func controls(_ file: URL) -> some View {
        if isEditing {
            if let saveError { Text(saveError).font(Tokens.Font.meta).foregroundStyle(Tokens.red) }
            Button("취소") { isEditing = false; saveError = nil }
            Button("저장") { save(file) }.keyboardShortcut("s", modifiers: .command)
        } else {
            if original != nil, loadedFile == file, FileTree.isEditable(file, in: barrack.url) {
                Button("편집") { draft = original ?? ""; isEditing = true }
                    .keyboardShortcut("e", modifiers: .command)
                    .help("이 파일 편집 (⌘E) · 저장은 ⌘S")
            }
            Menu {
                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                Button("기본 앱으로 열기") { NSWorkspace.shared.open(file) }
                Button("경로 복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("Finder에서 보기 · 기본 앱으로 열기 · 경로 복사")
        }
    }

    @ViewBuilder
    private func viewer(_ file: URL) -> some View {
        if isEditing {
            TextEditor(text: $draft)
                .font(.system(size: 13).monospaced())
                .padding(.horizontal, Tokens.Spacing.s)
        } else {
            switch loadedFile == file ? content : nil {
            case let .markdown(text)?:
                if let rendererFailure {
                    RawSourceView(source: text, reason: rendererFailure)
                } else {
                    // A SKILL.md-style frontmatter becomes a short header.
                    MarkdownWebView(source: BarrackDocuments.frontmatterAsHeader(text), documentURL: file,
                                    revision: text.hashValue, onRendererFailure: { rendererFailure = $0 })
                }
            case let .text(text)?:
                PlainTextView(text: text)
            case .image?:
                ImagePreview(file: file).id(revision)
            case .pdf?:
                PDFPreview(file: file).id(revision)
            case let .unavailable(reason)?:
                ContentUnavailableView {
                    Label("여기서 볼 수 없음", systemImage: "eye.slash")
                } description: {
                    Text(reason)
                } actions: {
                    Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            case nil:
                Color.clear
            }
        }
    }

    private func load() {
        rendererFailure = nil
        saveError = nil
        loadedFile = file
        revision += 1
        guard let file else {
            content = nil
            details = ""
            return
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            content = .unavailable("파일이 없어졌습니다.")
            details = FileTree.relativePath(of: file, under: barrack.url)
            return
        }
        content = FileTree.content(of: file)
        details = Self.details(of: file, in: barrack.url)
    }

    /// "wiki/topics · 12KB · 2026. 11. 16. 09:12"
    static func details(of file: URL, in barrack: URL) -> String {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let folder = (FileTree.relativePath(of: file, under: barrack) as NSString).deletingLastPathComponent
        let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        let modified = values?.contentModificationDate.map { $0.formatted(date: .numeric, time: .shortened) }
        return [folder.isEmpty ? nil : folder, size, modified].compactMap { $0 }.joined(separator: " · ")
    }

    private func save(_ file: URL) {
        guard let original else { return }
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
}

/// Read-only text in an AppKit text view: selectable, and a large file
/// scrolls without laying out every line up front.
private struct PlainTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context _: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.drawsBackground = false
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context _: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.scroll(.zero)
    }
}

/// An image no larger than its own size, fitted to the reader.
private struct ImagePreview: View {
    let file: URL

    var body: some View {
        if let image = NSImage(contentsOf: file) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                .padding(Tokens.Spacing.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("이미지를 열 수 없음", systemImage: "photo")
        }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let file: URL

    func makeNSView(context _: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: file)
        return view
    }

    func updateNSView(_ view: PDFView, context _: Context) {
        if view.document?.documentURL != file { view.document = PDFDocument(url: file) }
    }
}
