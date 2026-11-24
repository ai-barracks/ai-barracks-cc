import SwiftUI

/// Git destination (v1 GitTab): branch, ahead/behind, the barrack's
/// changes, commit with a message, push with confirmation, recent log.
/// In a monorepo everything except push is limited to the barrack path.
struct GitView: View {
    let workspace: WorkspaceModel
    let barrack: Barrack
    /// Bumped on any file event in the barrack.
    var changes = 0
    @State private var info = GitRepository.Info()
    @State private var message = ""
    @State private var busy = false
    @State private var result: GitRepository.Outcome?
    @State private var confirmPush = false

    private var repository: GitRepository { GitRepository(directory: barrack.path) }

    var body: some View {
        Group {
            if info.isRepo {
                content
            } else {
                ContentUnavailableView("Git 저장소가 아닙니다", systemImage: "arrow.triangle.branch",
                                       description: Text("이 배럭은 git으로 관리되지 않습니다."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.work)
        .task(id: barrack.id) { await reload() }
        .onChange(of: changes) { if !busy { Task { await reload() } } }
        .confirmationDialog(pushTitle, isPresented: $confirmPush) {
            Button("Push") { perform { await repository.push(info.state) } }
        } message: {
            Text(info.isSubPath ? "push는 저장소 전체 브랜치를 올립니다(이 배럭 밖의 커밋 포함)." : "현재 브랜치를 원격에 올립니다.")
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                summary
                changeList
                commitBox
                if let result { outcome(result) }
                logList
            }
            .padding(Tokens.Spacing.l)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(spacing: Tokens.Spacing.s) {
                Label(info.state.branch.isEmpty ? "(분리된 HEAD)" : info.state.branch, systemImage: "arrow.triangle.branch")
                    .font(Tokens.Font.body.weight(.semibold))
                Text(info.state.upstream.map { "↑\(info.state.ahead) ↓\(info.state.behind) · \($0)" } ?? "upstream 없음")
                    .font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
                Spacer()
                Button("변경 보기") { workspace.runInPane(title: "git diff", command: "git diff --stat -- . && git diff -- .") }
                Button("Push…") { confirmPush = true }.disabled(busy || info.state.branch.isEmpty)
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }
            .controlSize(.small)
            if !info.remote.isEmpty { Text(info.remote).font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary).textSelection(.enabled) }
            if info.isSubPath {
                Text("모노레포: 저장소 \((info.root as NSString).lastPathComponent)의 \(info.prefix) — 변경·커밋·로그는 이 배럭만 다룹니다.")
                    .font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
            }
        }
    }

    private var changeList: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text("변경 \(info.state.changes.count) · staged \(info.state.staged) · 수정 \(info.state.modified) · 새 파일 \(info.state.untracked)")
                .font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
            if info.state.changes.isEmpty {
                Text("변경 없음").font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
            }
            ForEach(info.state.changes.prefix(AppConstants.Git.visibleChanges)) { change in
                HStack(spacing: Tokens.Spacing.s) {
                    Text(verbatim: change.kind == .untracked ? "??" : String([change.index, change.worktree]))
                        .font(.system(size: 11).monospaced()).foregroundStyle(change.isStaged ? Tokens.teal : Tokens.orange)
                        .frame(width: 22, alignment: .leading)
                    Text(relative(change.path)).font(.system(size: 12).monospaced()).lineLimit(1).truncationMode(.middle)
                    if let original = change.originalPath {
                        Text("← \(relative(original))").font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary).lineLimit(1)
                    }
                }
            }
        }
    }

    private var commitBox: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.s) {
            TextField("커밋 메시지", text: $message, prompt: Text("type: 무엇을 왜"), axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            Button(busy ? "작업 중…" : "커밋 (\(info.state.changes.count))") {
                let text = message
                perform({ await repository.commit(message: text) }, then: { if $0.ok { message = "" } })
            }
            .disabled(busy || info.state.changes.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func outcome(_ result: GitRepository.Outcome) -> some View {
        Text(result.output.isEmpty ? (result.ok ? "완료" : "실패") : result.output)
            .font(.system(size: 11).monospaced())
            .foregroundStyle(result.ok ? Tokens.textSecondary : Tokens.red)
            .textSelection(.enabled)
            .lineLimit(12)
            .padding(Tokens.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((result.ok ? Tokens.teal : Tokens.red).opacity(0.08), in: RoundedRectangle(cornerRadius: Tokens.Radius.row))
    }

    private var logList: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(info.isSubPath ? "최근 커밋(이 배럭)" : "최근 커밋").font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
            ForEach(info.log) { entry in
                HStack(spacing: Tokens.Spacing.s) {
                    Text(entry.hash).font(.system(size: 11).monospaced()).foregroundStyle(Tokens.textTertiary)
                    Text(entry.subject).font(Tokens.Font.body).lineLimit(1)
                    Spacer()
                    Text("\(entry.author) · \(entry.when)").font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
                }
            }
        }
    }

    private var pushTitle: String {
        guard let upstream = info.state.upstream else {
            return "upstream이 없습니다. origin/\(info.state.branch)에 push하고 upstream으로 설정할까요?"
        }
        return "\(upstream)에 push할까요? 올라갈 커밋 \(info.state.ahead)개"
    }

    private func relative(_ path: String) -> String {
        path.hasPrefix(info.prefix) ? String(path.dropFirst(info.prefix.count)) : "../" + path
    }

    private func perform(_ operation: @escaping () async -> GitRepository.Outcome,
                         then: @escaping (GitRepository.Outcome) -> Void = { _ in }) {
        busy = true
        Task {
            let outcome = await operation()
            result = outcome
            then(outcome)
            busy = false
            await reload()
        }
    }

    private func reload() async {
        info = await repository.info()
    }
}
