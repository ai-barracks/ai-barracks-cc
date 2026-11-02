import SwiftUI

/// Kept terminal output (v1 archive tab): this barrack's or all, read-only
/// text, export to the barrack's sessions/, delete one or all.
struct ScrollbackArchiveView: View {
    let workspace: WorkspaceModel
    let barrack: Barrack
    @State private var entries: [ArchivedOutput] = []
    @State private var allBarracks = false
    @State private var query = ""
    @State private var selection: ArchivedOutput.ID?
    @State private var text = ""
    @State private var confirmDeleteAll = false

    private var filtered: [ArchivedOutput] {
        entries.filter { allBarracks || $0.barrackPath == barrack.path }
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    TextField("제목 검색", text: $query).textFieldStyle(.roundedBorder)
                    Toggle("모든 배럭", isOn: $allBarracks).toggleStyle(.checkbox)
                }
                .padding(Tokens.Spacing.s)
                List(filtered, selection: $selection) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(Tokens.Font.bodyMedium).lineLimit(1)
                        Text("\(entry.closedAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(entry.byteLength), countStyle: .file))\(entry.truncated ? " · 앞부분 잘림" : "")")
                            .font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
                    }
                    .tag(entry.id)
                }
                HStack {
                    Text("\(filtered.count)개 · \(AppConstants.Scrollback.retention / 86_400, specifier: "%.0f")일 보관")
                        .font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
                    Spacer()
                    Button("모두 삭제…") { confirmDeleteAll = true }.disabled(entries.isEmpty)
                }
                .padding(6)
            }
            .frame(width: AppConstants.Documents.historyListWidth)
            Divider()
            reader
        }
        .background(Tokens.work)
        .task(id: workspace.archiveRevision) { reload() }
        .onChange(of: selection) { loadText() }
        .confirmationDialog("보관한 터미널 출력을 모두 지울까요?", isPresented: $confirmDeleteAll) {
            Button("모두 삭제", role: .destructive) { workspace.deleteAllArchived() }
        } message: {
            Text("모든 배럭의 보관 출력 \(entries.count)개가 지워집니다. 되돌릴 수 없습니다.")
        }
    }

    @ViewBuilder
    private var reader: some View {
        if let entry = filtered.first(where: { $0.id == selection }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(entry.barrackPath.map { ($0 as NSString).lastPathComponent } ?? "—").font(Tokens.Font.meta)
                        .foregroundStyle(Tokens.textSecondary)
                    Spacer()
                    Button("배럭 sessions/로 내보내기") { export(entry) }.disabled(entry.barrackPath == nil)
                    Button("삭제", role: .destructive) { workspace.deleteArchived(entry.id) }
                }
                .controlSize(.small)
                .padding(Tokens.Spacing.m)
                ScrollView {
                    Text(text).font(.system(size: 12).monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Tokens.Spacing.m)
                }
            }
        } else {
            ContentUnavailableView("보관한 출력을 선택하세요", systemImage: "archivebox",
                                   description: Text("pane을 닫거나 프로그램이 끝나면 화면 내용이 여기 남습니다."))
        }
    }

    private func reload() {
        entries = workspace.scrollback.list()
        if selection.map({ id in !filtered.contains { $0.id == id } }) ?? true { selection = filtered.first?.id }
        loadText()
    }

    private func loadText() {
        text = selection.flatMap { workspace.scrollback.text(of: $0) } ?? ""
    }

    private func export(_ entry: ArchivedOutput) {
        guard let path = entry.barrackPath else { return }
        switch TerminalExport.write(text, barrackPath: path, title: entry.title, now: entry.closedAt) {
        case let .success(url):
            workspace.notices.post(AppNotice(kind: .export, title: "출력 내보냄", body: url.path, actionLabel: "Finder에서 보기",
                                             barrackID: nil, sessionID: url.path))
        case .failure:
            workspace.notices.post(AppNotice(kind: .export, title: "내보내지 못함", body: "같은 이름 파일이 있거나 쓸 수 없습니다",
                                             actionLabel: nil, barrackID: nil, sessionID: nil))
        }
    }
}

/// "기록" destination: session records (v1 Sessions tab) and kept
/// terminal output (v1 archive).
struct HistoryDestinationView: View {
    let workspace: WorkspaceModel
    let barrack: Barrack
    var changes = 0
    @State private var showArchive = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $showArchive) {
                Text("세션 기록").tag(false)
                Text("터미널 출력").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .padding(Tokens.Spacing.s)
            Divider()
            if showArchive {
                ScrollbackArchiveView(workspace: workspace, barrack: barrack)
            } else {
                SessionHistoryView(workspace: workspace, barrack: barrack, changes: changes)
            }
        }
        .onChange(of: workspace.pendingSessionID) { if workspace.pendingSessionID != nil { showArchive = false } }
    }
}
