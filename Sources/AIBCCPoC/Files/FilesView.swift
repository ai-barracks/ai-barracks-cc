import SwiftUI

/// The barrack's folder as a tree, and the picked file beside it
/// (2026-11-16 request). Folders open on a click or with →; a file opens
/// in the reader: Markdown rendered, text as is, images and PDFs previewed.
struct FilesView: View {
    let workspace: WorkspaceModel
    let barrack: Barrack
    /// Bumped on any file event in the barrack.
    var changes = 0
    @AppStorage(AppConstants.Files.showHiddenKey) private var showHidden = false
    @AppStorage(AppConstants.Files.sortKeyKey) private var sortKey = FileOrder.Key.name
    @AppStorage(AppConstants.Files.sortAscendingKey) private var sortAscending = true
    @State private var rows: [FileTree.Row] = []
    @State private var loaded = false
    @State private var refresh = 0
    @State private var isDirty = false
    /// A file picked in the tree while an edit was open (asks first).
    @State private var leaveTarget: URL?

    private var browser: FileBrowserModel { workspace.fileBrowser }
    private var state: FileBrowserModel.State { browser.state(of: barrack) }
    private var order: FileOrder { FileOrder(key: sortKey, ascending: sortAscending) }

    var body: some View {
        ListDetailSplit(widthKey: AppConstants.Files.listKey, defaultWidth: AppConstants.Files.listWidth) {
            tree
        } detail: {
            FileReaderView(barrack: barrack, file: state.opened, changes: changes + refresh,
                           isDirty: $isDirty,
                           editInProgress: Binding(get: { workspace.editInProgress }, set: { workspace.editInProgress = $0 }),
                           discardRevision: workspace.discardRevision)
        }
        .background(Tokens.work)
        .task(id: Listing(barrack: barrack.id, expanded: state.expanded, showHidden: showHidden, order: order,
                          changes: changes, refresh: refresh)) {
            let root = barrack.url
            let expanded = state.expanded
            let hidden = showHidden
            let order = order
            rows = await Task.detached { FileTree.rows(root: root, expanded: expanded, showHidden: hidden, order: order) }.value
            loaded = true
        }
        .alert("편집 중입니다", isPresented: Binding(get: { leaveTarget != nil }, set: { if !$0 { leaveTarget = nil } })) {
            Button("편집 버리고 이동", role: .destructive) {
                if let target = leaveTarget { browser.open(target, in: barrack) }
                leaveTarget = nil
            }
            Button("계속 편집", role: .cancel) { leaveTarget = nil }
        } message: {
            Text("저장하지 않은 편집이 있습니다.")
        }
    }

    private var tree: some View {
        VStack(spacing: 0) {
            HStack(spacing: Tokens.Spacing.s) {
                Text(barrack.name).font(Tokens.Font.meta.weight(.semibold)).foregroundStyle(Tokens.textSecondary).lineLimit(1)
                Spacer(minLength: 4)
                sortMenu
                Button { showHidden.toggle() } label: { Image(systemName: showHidden ? "eye" : "eye.slash") }
                    .help(showHidden ? "숨김 파일 감추기" : "숨김 파일 보기(.으로 시작하는 파일·폴더)")
                Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help("목록 새로 고침")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Tokens.Spacing.m)
            .padding(.vertical, Tokens.Spacing.s)
            List(selection: highlight) {
                ForEach(rows) { row in
                    FileRowView(row: row, isExpanded: state.expanded.contains(row.node.url), date: order.date(of: row.node)) {
                        browser.highlight(row.node.url, in: barrack)
                        browser.toggle(row.node.url, in: barrack)
                    }
                    .tag(row.node.url)
                }
            }
            .listStyle(.sidebar)
            // Finder's keys: → opens the highlighted folder, ← closes it.
            .onKeyPress(.rightArrow) { setHighlightedFolder(open: true) }
            .onKeyPress(.leftArrow) { setHighlightedFolder(open: false) }
            .overlay {
                if loaded, rows.isEmpty { ContentUnavailableView("파일 없음", systemImage: "folder") }
            }
        }
    }

    /// Name, modified date or created date; picking the key in use again
    /// reverses it. Applies inside every folder, folders first.
    private var sortMenu: some View {
        Menu {
            Section("정렬") {
                ForEach(FileOrder.Key.allCases) { key in
                    Button {
                        if key == sortKey {
                            sortAscending.toggle()
                        } else {
                            sortKey = key
                            sortAscending = FileOrder.initial(key).ascending
                        }
                    } label: {
                        if key == sortKey { Label(key.label, systemImage: "checkmark") } else { Text(key.label) }
                    }
                }
            }
            Section {
                Picker("순서", selection: $sortAscending) {
                    Text(sortKey == .name ? "가나다순 (A→Z)" : "오래된 것 먼저").tag(true)
                    Text(sortKey == .name ? "역순 (Z→A)" : "최신 먼저").tag(false)
                }
                .pickerStyle(.inline)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("정렬: \(sortKey.label) · \(sortAscending ? (sortKey == .name ? "A→Z" : "오래된 것 먼저") : (sortKey == .name ? "Z→A" : "최신 먼저"))")
    }

    /// Highlighting a file opens it (asking first when an edit is open);
    /// a folder is only highlighted, so the arrow keys can pass over it.
    private var highlight: Binding<URL?> {
        Binding(get: { state.highlighted }, set: { url in
            guard let url, let row = rows.first(where: { $0.node.url == url }) else {
                return browser.highlight(url, in: barrack)
            }
            if row.node.isDirectory || url == state.opened {
                browser.highlight(url, in: barrack)
            } else if isDirty {
                leaveTarget = url
            } else {
                browser.open(url, in: barrack)
            }
        })
    }

    private func setHighlightedFolder(open: Bool) -> KeyPress.Result {
        guard let url = state.highlighted, rows.contains(where: { $0.node.url == url && $0.node.isDirectory }) else { return .ignored }
        browser.setExpanded(url, open, in: barrack)
        return .handled
    }

    private struct Listing: Equatable {
        let barrack: Barrack.ID
        let expanded: Set<URL>
        let showHidden: Bool
        let order: FileOrder
        let changes: Int
        let refresh: Int
    }
}

/// One line of the tree: indent, a chevron for folders, icon, name.
private struct FileRowView: View {
    let row: FileTree.Row
    let isExpanded: Bool
    /// Shown at the end of the row when the tree is ordered by a date.
    let date: Date?
    let toggle: () -> Void

    var body: some View {
        let label = HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(Tokens.textTertiary)
                .opacity(row.node.isDirectory ? 1 : 0)
                .frame(width: 10)
            Image(systemName: row.node.isDirectory ? (isExpanded ? "folder.fill" : "folder") : FileTree.kind(of: row.node.url).symbol)
                .foregroundStyle(row.node.isDirectory ? Tokens.teal : Tokens.textSecondary)
                .frame(width: 16)
            Text(row.node.name).font(Tokens.Font.body).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if let date {
                Text(Self.short(date)).font(Tokens.Font.numeric).foregroundStyle(Tokens.textTertiary).lineLimit(1).fixedSize()
            }
        }
        .padding(.leading, CGFloat(row.depth) * AppConstants.Files.indent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(Self.tooltip(row.node))
        if row.node.isDirectory {
            label.onTapGesture(perform: toggle)
        } else {
            label
        }
    }

    /// Time today, month and day this year, else the full date.
    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.month(.defaultDigits).day()) }
        return date.formatted(date: .numeric, time: .omitted)
    }

    private static func tooltip(_ node: FileNode) -> String {
        let dates = [node.modified.map { "수정 \($0.formatted(date: .numeric, time: .shortened))" },
                     node.created.map { "생성 \($0.formatted(date: .numeric, time: .shortened))" }].compactMap { $0 }
        return ([node.name] + dates).joined(separator: "\n")
    }
}
