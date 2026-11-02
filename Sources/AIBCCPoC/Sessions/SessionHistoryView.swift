import SwiftUI

/// "기록" destination (v1 Sessions tab parity): every session record of
/// the barrack, filters, a structured detail with the seal check, and
/// Continue / Monitor running in terminal panes.
struct SessionHistoryView: View {
    let workspace: WorkspaceModel
    let barrack: Barrack
    var changes = 0
    @State private var records: [SessionRecord] = []
    @State private var status = StatusFilter.all
    @State private var client = "all"
    @State private var selection: SessionRecord.ID?
    @State private var detail: SessionDetail?

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all, active, completed, interrupted
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "전체"
            case .active: "진행 중"
            case .completed: "완료"
            case .interrupted: "중단"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                filters
                List(filtered, selection: $selection) { record in
                    SessionRow(record: record, live: live(for: record)).tag(record.id)
                }
                Text("\(filtered.count) / \(records.count)").font(Tokens.Font.meta)
                    .foregroundStyle(Tokens.textTertiary).padding(6)
            }
            .frame(width: AppConstants.Documents.historyListWidth)
            Divider()
            if let detail {
                SessionDetailView(detail: detail, workspace: workspace)
                    .id(detail.record.id)
            } else {
                ContentUnavailableView("세션을 선택하세요", systemImage: "clock.arrow.circlepath")
            }
        }
        .background(Tokens.work)
        .task(id: barrack.id) { reload(); takePending() }
        .onChange(of: workspace.pendingSessionID) { takePending() }
        .onChange(of: workspace.liveness.sessions) { reload() }
        .onChange(of: changes) {
            reload()
            detail = selection.flatMap { SessionRecords.detail(barrackPath: barrack.path, id: $0) }
        }
        .onChange(of: selection) {
            detail = selection.flatMap { SessionRecords.detail(barrackPath: barrack.path, id: $0) }
            acknowledgeIfDone()
        }
    }

    private var filters: some View {
        VStack(spacing: Tokens.Spacing.s) {
            Picker("", selection: $status) { ForEach(StatusFilter.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            Picker("클라이언트", selection: $client) {
                Text("모든 클라이언트").tag("all")
                ForEach(Array(Set(records.map(\.client))).sorted(), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        }
        .padding(Tokens.Spacing.s)
    }

    private var filtered: [SessionRecord] {
        records.filter { (status == .all || $0.status == status.rawValue) && (client == "all" || $0.client == client) }
    }

    private func live(for record: SessionRecord) -> LiveSession? {
        workspace.liveness.sessions(of: barrack.id).first { $0.id == record.id }
    }

    private func takePending() {
        guard let wanted = workspace.pendingSessionID, records.contains(where: { $0.id == wanted }) else { return }
        workspace.pendingSessionID = nil
        status = .all
        client = "all"
        selection = wanted
    }

    private func reload() {
        records = SessionRecords.list(barrackPath: barrack.path)
    }

    /// v1: opening a `done` card acknowledges its run (never a blocked one).
    private func acknowledgeIfDone() {
        guard let id = selection, let session = workspace.liveness.sessions(of: barrack.id).first(where: { $0.id == id }),
              session.state == .done
        else { return }
        LivenessAck.write(barrackPath: barrack.path, sessionID: session.id, runID: session.runID)
        workspace.liveness.refresh()
    }
}

private struct SessionRow: View {
    let record: SessionRecord
    let live: LiveSession?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            LivenessBeacon(state: live?.state ?? (record.status == "active" ? .working : .idle))
            VStack(alignment: .leading, spacing: 2) {
                Text(record.task.isEmpty || record.task == "(pending)" ? record.id : record.task)
                    .font(Tokens.Font.body).lineLimit(2)
                Text("\(record.client) · \(record.started) · \(record.status)")
                    .font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SessionDetailView: View {
    let detail: SessionDetail
    let workspace: WorkspaceModel
    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(Tokens.Spacing.l)
            if detail.seal == .modified || detail.seal == .invalid { sealBanner }
            Divider()
            if showRaw {
                MarkdownWebView(source: detail.raw, documentURL: nil, revision: detail.raw.hashValue, onRendererFailure: { _ in })
            } else {
                sections
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(detail.record.task.isEmpty ? detail.record.id : detail.record.task).font(Tokens.Font.title)
            Text("\(detail.record.client) · \(detail.record.started) → \(detail.record.ended) · \(detail.record.status)")
                .font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
            if !detail.record.continues.isEmpty && detail.record.continues != "(없음)" {
                Label("이어받음: \(detail.record.continues)", systemImage: "arrow.turn.down.right")
                    .font(Tokens.Font.meta).foregroundStyle(Tokens.teal)
            }
            HStack {
                Menu("Continue") {
                    ForEach(["claude", "codex", "gemini"], id: \.self) { client in
                        Button(client == detail.record.clientKey ? "\(client) (같은 클라이언트)" : client) {
                            workspace.runInPane(title: "continue", command: SessionRecords.continueCommand(client: client, sessionID: detail.record.id))
                        }
                    }
                }
                .disabled(!detail.record.canContinue)
                .fixedSize()
                Button("Monitor") {
                    workspace.runInPane(title: "monitor", command: SessionRecords.monitorCommand(sessionID: detail.record.id))
                }
                Toggle("원문", isOn: $showRaw).toggleStyle(.button)
            }
            .controlSize(.small)
        }
    }

    private var sealBanner: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tokens.orange)
            Text(detail.seal == .modified ? "종료 후 봉인된 기록이 바뀌었습니다." : "봉인을 검증할 수 없습니다.")
            Text("승인: 터미널에서 aib sessions seal \(detail.record.id)").foregroundStyle(Tokens.textSecondary)
        }
        .font(Tokens.Font.meta)
        .padding(Tokens.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.orange.opacity(0.12))
    }

    private var sections: some View {
        List {
            group("Log", detail.log)
            group("Decisions", detail.decisions)
            group("Blockers", detail.blockers)
            group("Wiki Extractions", detail.wikiExtractions)
            group("Identity Suggestions", detail.identitySuggestions)
            if let violations = detail.violations {
                Section("Violations") { Text(violations).font(.system(size: 11).monospaced()) }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            Section("\(title) (\(items.count))") {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item).font(Tokens.Font.body).textSelection(.enabled)
                }
            }
        }
    }
}
