import SwiftUI

/// Skills destination (v1 SkillsTab): searchable catalog, SKILL.md reader,
/// create / edit / rename / delete, and `aib sync` after every change with
/// a retry banner when it fails (the file change is kept either way).
struct SkillsView: View {
    let barrack: Barrack
    /// Bumped on any file event in the barrack.
    var changes = 0
    @Binding var pending: URL?
    /// Opens the selected skill's editor (gallery).
    @Binding var pendingEdit: Bool
    var sync: AibSync.Runner = AibSync.apply
    @State private var skills: [SkillEntry] = []
    @State private var query = ""
    @State private var selection: String?
    @State private var source: String?
    @State private var renderFailure: String?
    @State private var sheet: SkillSheet?
    @State private var syncState = SyncState.idle
    /// aib's seeded skills: sync re-creates them, so no delete or rename.
    @State private var defaultSkills: Set<String> = []

    enum SyncState: Equatable { case idle, running, done, failed(String) }

    var body: some View {
        ListDetailSplit(widthKey: AppConstants.Documents.skillListKey, defaultWidth: AppConstants.Documents.historyListWidth) {
            catalog
        } detail: {
            reader
        }
        .background(Tokens.work)
        .onAppear(perform: reload)
        .task { defaultSkills = await AibTemplates.defaultSkills() }
        .onChange(of: barrack.id) { selection = nil; reload() }
        .onChange(of: changes) { reload() }
        .onChange(of: pending) { takePending() }
        .onChange(of: pendingEdit) { takePendingEdit() }
        .onChange(of: selection) { loadSource() }
        .sheet(item: $sheet) { item in sheetView(item) }
    }

    private var filtered: [SkillEntry] {
        guard !query.isEmpty else { return skills }
        return skills.filter { [$0.slug, $0.name, $0.description].contains { $0.localizedCaseInsensitiveContains(query) } }
    }

    private var catalog: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Skill 검색", text: $query).textFieldStyle(.roundedBorder)
                Button { sheet = .create } label: { Image(systemName: "plus") }
                    .help("새 Skill")
            }
            .padding(Tokens.Spacing.s)
            List(filtered, selection: $selection) { skill in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(skill.slug).font(Tokens.Font.body.weight(.medium))
                        if skill.problem != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tokens.orange) }
                    }
                    Text(skill.problem ?? skill.description).font(Tokens.Font.meta)
                        .foregroundStyle(skill.problem == nil ? Tokens.textSecondary : Tokens.orange).lineLimit(2)
                }
                .tag(skill.slug)
            }
            .listStyle(.sidebar)
            .overlay {
                if skills.isEmpty {
                    ContentUnavailableView {
                        Label("Skills 없음", systemImage: "puzzlepiece.extension")
                    } description: {
                        Text("skills/<slug>/SKILL.md — 에이전트가 호출하는 능력입니다.")
                    } actions: {
                        Button("새 Skill") { sheet = .create }
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }

    @ViewBuilder
    private var reader: some View {
        VStack(alignment: .leading, spacing: 0) {
            syncBanner
            if let skill = selected {
                HStack {
                    OwnershipSeal(ownership: .user)
                    Spacer()
                    let seeded = defaultSkills.contains(skill.slug)
                    if seeded {
                        Text("aib 기본 skill — 지우거나 이름을 바꾸면 aib sync가 다시 만듭니다")
                            .font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary).lineLimit(1)
                            .help("aib 기본 skill — 지우거나 이름을 바꾸면 aib sync가 다시 만듭니다")
                    }
                    Button("편집") { openEditor(skill) }
                    Button("이름 변경") { sheet = .rename(skill) }.disabled(seeded)
                    Button("삭제", role: .destructive) { sheet = .delete(skill) }.disabled(seeded)
                }
                .padding(Tokens.Spacing.m)
                if let source, let renderFailure {
                    RawSourceView(source: source, reason: renderFailure)
                } else if let source {
                    MarkdownWebView(source: source, documentURL: skill.file, revision: source.hashValue,
                                    onRendererFailure: { renderFailure = $0 })
                }
            } else {
                ContentUnavailableView("Skill을 선택하세요", systemImage: "puzzlepiece.extension")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var syncBanner: some View {
        switch syncState {
        case .idle:
            EmptyView()
        case .running:
            banner(Label("aib sync 중…", systemImage: "arrow.triangle.2.circlepath"), color: Tokens.textSecondary) {}
        case .done:
            banner(Label("저장됨 · aib sync 완료", systemImage: "checkmark.circle"), color: Tokens.teal) {}
        case let .failed(reason):
            banner(Label("저장됨 · aib sync 실패: \(reason)", systemImage: "exclamationmark.triangle"), color: Tokens.orange) {
                Button("다시 sync") { runSync() }
                Button("닫기") { syncState = .idle }
            }
        }
    }

    private func banner(_ label: some View, color: Color, @ViewBuilder actions: () -> some View) -> some View {
        HStack {
            label.font(Tokens.Font.meta).foregroundStyle(color).lineLimit(1)
            Spacer()
            actions()
        }
        .padding(.horizontal, Tokens.Spacing.m)
        .padding(.vertical, Tokens.Spacing.s)
        .background(color.opacity(0.10))
    }

    private var selected: SkillEntry? {
        skills.first { $0.slug == selection }
    }

    @ViewBuilder
    private func sheetView(_ item: SkillSheet) -> some View {
        switch item {
        case .create:
            SkillEditorSheet(barrack: barrack.url, mode: .create, onSaved: changed)
        case let .edit(skill, original):
            SkillEditorSheet(barrack: barrack.url, mode: .edit(slug: skill.slug, original: original), onSaved: changed)
        case let .rename(skill):
            SkillRenameSheet(barrack: barrack.url, slug: skill.slug, onRenamed: changed)
        case let .delete(skill):
            SkillDeleteSheet(barrack: barrack.url, slug: skill.slug) { changed(nil) }
        }
    }

    private func openEditor(_ skill: SkillEntry) {
        guard let raw = try? String(contentsOf: skill.file, encoding: .utf8) else { return }
        sheet = .edit(skill, raw)
    }

    /// After any change: reload, select the result, then sync.
    private func changed(_ slug: String?) {
        reload()
        selection = slug ?? skills.first?.slug
        runSync()
    }

    private func runSync() {
        syncState = .running
        let barrackURL = barrack.url
        Task {
            switch await sync(barrackURL) {
            case let .failed(reason):
                syncState = .failed(reason)
            case .ok:
                syncState = .done
                try? await Task.sleep(for: .seconds(4))
                if syncState == .done { syncState = .idle }
            }
        }
    }

    private func reload() {
        skills = SkillFiles.list(in: barrack.url)
        if selection.map({ slug in !skills.contains { $0.slug == slug } }) ?? true { selection = skills.first?.slug }
        takePending()
        loadSource()
    }

    private func loadSource() {
        renderFailure = nil
        source = selected.flatMap { try? String(contentsOf: $0.file, encoding: .utf8) }.map(BarrackDocuments.frontmatterAsHeader)
        takePendingEdit()
    }

    private func takePending() {
        guard let wanted = pending?.standardizedFileURL else { return }
        let slug = wanted.lastPathComponent == "SKILL.md" ? wanted.deletingLastPathComponent().lastPathComponent : nil
        guard let slug, skills.contains(where: { $0.slug == slug }) else { return }
        pending = nil
        selection = slug
    }

    private func takePendingEdit() {
        guard pendingEdit, pending == nil, let skill = selected else { return }
        pendingEdit = false
        openEditor(skill)
    }
}

enum SkillSheet: Identifiable {
    case create
    case edit(SkillEntry, String)
    case rename(SkillEntry)
    case delete(SkillEntry)

    var id: String {
        switch self {
        case .create: "create"
        case let .edit(skill, _): "edit-\(skill.slug)"
        case let .rename(skill): "rename-\(skill.slug)"
        case let .delete(skill): "delete-\(skill.slug)"
        }
    }
}
