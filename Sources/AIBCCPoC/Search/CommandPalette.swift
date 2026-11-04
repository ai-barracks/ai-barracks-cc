import SwiftUI

/// One row of the ⌘K palette: a command or a search hit.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let section: String
    let run: @MainActor () -> Void
}

/// ⌘K (v1 parity G1): commands and cross-barrack search in one list.
/// Type to filter, ↑/↓ to move, Enter to run, Esc to close.
struct CommandPalette: View {
    let workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("명령 또는 검색 (배럭 전체: 세션·Wiki·규칙·SOUL·GROWTH)", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .padding(Tokens.Spacing.l)
                .focused($focused)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onSubmit { runSelected() }
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item, isSelected: index == selected)
                            .id(index)
                            .onTapGesture { selected = index; runSelected() }
                    }
                }
                .onChange(of: selected) { proxy.scrollTo(selected) }
            }
        }
        .frame(width: 640, height: 440)
        .onAppear { focused = true }
        .task(id: query) {
            selected = 0
            try? await Task.sleep(for: .milliseconds(150))
            let barracks = workspace.barracks
            let text = query
            hits = await Task.detached { SearchIndex.search(text, in: barracks) }.value
        }
    }

    private var items: [PaletteItem] {
        let commands = PaletteCommands.all(workspace: workspace).filter { PaletteCommands.matches($0, query) }
        let found = hits.map { hit in
            PaletteItem(id: hit.id, title: "\(hit.barrackName) · \(hit.title)", detail: hit.snippet,
                        symbol: hit.source == .session ? "clock.arrow.circlepath" : hit.source == .wiki ? "books.vertical" : "list.bullet.rectangle",
                        section: "검색") { workspace.open(hit) }
        }
        return commands + found
    }

    private func row(_ item: PaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            Image(systemName: item.symbol).frame(width: 18).foregroundStyle(isSelected ? Tokens.teal : Tokens.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(Tokens.Font.body).lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail).font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary).lineLimit(1)
                }
            }
            Spacer()
            Text(item.section).font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.row).fill(isSelected ? Tokens.teal.opacity(0.16) : .clear))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        selected = (selected + delta + count) % count
    }

    private func runSelected() {
        let list = items
        guard list.indices.contains(selected) else { return }
        dismiss()
        let item = list[selected]
        workspace.navigate { item.run() }
    }
}

/// The palette's commands (v1: aib, git, agent, terminal, navigation).
enum PaletteCommands {
    @MainActor
    static func all(workspace: WorkspaceModel) -> [PaletteItem] {
        let pane = { (title: String, command: String) -> @MainActor @Sendable () -> Void in
            { workspace.runInPane(title: title, command: command) }
        }
        var items: [PaletteItem] = [
            .init(id: "agent", title: "새 에이전트", detail: "⌘N · aib start", symbol: "sparkles", section: "에이전트") {
                workspace.isNewAgentSheetPresented = true
            },
            .init(id: "terminal", title: "새 터미널", detail: "로그인 셸", symbol: "terminal", section: "에이전트") {
                workspace.launchAgent(.terminal, skipPermissions: false)
            },
            .init(id: "attention", title: "다음 주의 항목으로", detail: "⌘⇧A", symbol: "exclamationmark.circle", section: "에이전트") {
                workspace.goToNextAttention()
            },
            .init(id: "council", title: "Council 시작", detail: "⌘⇧C · aib council", symbol: "person.3", section: "aib") {
                workspace.isCouncilSheetPresented = true
            },
            .init(id: "aib-status", title: "aib status", detail: "현재 배럭 상태", symbol: "info.circle", section: "aib",
                  run: pane("aib status", "aib status")),
            .init(id: "aib-sync", title: "aib sync", detail: "dry-run 후 Enter로 적용", symbol: "arrow.triangle.2.circlepath", section: "aib",
                  run: pane("aib sync", MaintenanceScanner.confirmThenApply("aib sync --dry-run .", "aib sync ."))),
            .init(id: "sync-all", title: "모든 배럭 Sync", detail: "Sync All · dry-run 후 Enter로 적용",
                  symbol: "arrow.triangle.2.circlepath.circle", section: "aib") { workspace.syncAll(paths: []) },
            .init(id: "aib-lint", title: "aib wiki lint", detail: "위키 검증", symbol: "checkmark.seal", section: "aib",
                  run: pane("wiki lint", "aib wiki lint")),
            .init(id: "aib-barracks", title: "배럭 목록", detail: "aib barracks list", symbol: "list.bullet", section: "aib",
                  run: pane("barracks", "aib barracks list")),
            .init(id: "barrack-add", title: "배럭 추가", detail: "폴더 선택 → aib init", symbol: "plus.rectangle.on.folder", section: "aib") {
                workspace.isAddBarrackPresented = true
            },
            .init(id: "barrack-refresh", title: "배럭 목록 새로 고침", detail: "aib barracks refresh", symbol: "arrow.clockwise",
                  section: "aib") { workspace.refreshBarracks() },
            .init(id: "git-status", title: "git status", detail: "", symbol: "arrow.triangle.branch", section: "git", run: pane("git status", "git status")),
            .init(id: "git-diff", title: "git diff", detail: "", symbol: "arrow.triangle.branch", section: "git", run: pane("git diff", "git diff")),
            .init(id: "git-add", title: "git add -p", detail: "대화형 스테이징", symbol: "arrow.triangle.branch", section: "git", run: pane("git add -p", "git add -p")),
            .init(id: "git-graph", title: "git log --graph", detail: "", symbol: "arrow.triangle.branch", section: "git",
                  run: pane("git log", "git log --graph --oneline --decorate -50")),
        ]
        items += workspace.quickCommands.commands.map { quick in
            PaletteItem(id: "quick-\(quick.id)", title: "Quick: \(quick.label)", detail: quick.command, symbol: "bolt",
                        section: "Quick") { workspace.run(quick) }
        }
        items.append(PaletteItem(id: "quick-manage", title: "Quick Commands 추가·관리", detail: "", symbol: "bolt.badge.clock",
                                 section: "Quick") { workspace.quickCommandDraft = QuickCommand(label: "", command: "") })
        items += Destination.allCases.map { destination in
            PaletteItem(id: "go-\(destination.rawValue)", title: "이동: \(destination.label)", detail: "", symbol: destination.symbol,
                        section: "이동") { workspace.destination = destination }
        }
        items += workspace.barracks.map { barrack in
            PaletteItem(id: "barrack-\(barrack.id)", title: "배럭: \(barrack.name)", detail: barrack.description ?? "",
                        symbol: "building.2", section: "이동") { workspace.selectedBarrackID = barrack.id }
        }
        return items
    }

    static func matches(_ item: PaletteItem, _ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return !item.id.hasPrefix("barrack-") }
        return item.title.lowercased().contains(needle) || item.detail.lowercased().contains(needle)
    }
}
