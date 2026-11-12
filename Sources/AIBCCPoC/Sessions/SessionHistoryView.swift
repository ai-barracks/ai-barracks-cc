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
    /// v1 hid empty sessions by default (Codex parity audit P09).
    @AppStorage(AppConstants.History.hideEmptyKey) private var hideEmpty = true
    @State private var selection: SessionRecord.ID?
    @State private var detail: SessionDetail?
    /// Shown because nothing was picked (newest first); not "opened".
    @State private var autoSelected: SessionRecord.ID?

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
        ListDetailSplit(widthKey: AppConstants.Documents.historyListKey, defaultWidth: AppConstants.Documents.historyListWidth) {
            VStack(spacing: 0) {
                filters
                List(filtered, selection: $selection) { record in
                    SessionRow(record: record, live: live(for: record)).tag(record.id)
                }
                Text("\(filtered.count) / \(records.count)").font(Tokens.Font.meta)
                    .foregroundStyle(Tokens.textTertiary).padding(6)
            }
        } detail: {
            if let detail {
                SessionDetailView(detail: detail, workspace: workspace)
                    .id(detail.record.id)
            } else {
                ContentUnavailableView(filtered.isEmpty ? "표시할 세션이 없습니다" : "세션을 선택하세요", systemImage: "clock.arrow.circlepath")
            }
        }
        .background(Tokens.work)
        .task(id: barrack.id) { reload(); takePending(); selectNewestIfNone() }
        .onChange(of: filtered.map(\.id)) { selectNewestIfNone() }
        .onChange(of: workspace.pendingSessionID) { takePending() }
        .onChange(of: workspace.liveness.sessions) { reload() }
        .onChange(of: changes) {
            reload()
            detail = selection.flatMap { SessionRecords.detail(barrackPath: barrack.path, id: $0) }
        }
        .onChange(of: selection) {
            detail = selection.flatMap { SessionRecords.detail(barrackPath: barrack.path, id: $0) }
            // Only a session the user opened counts as seen.
            if selection != autoSelected { acknowledgeIfDone() }
        }
    }

    /// The segmented bar when the list is wide enough for it; menus when
    /// the list is at its narrowest (a minimum window with Outputs open:
    /// the bar ran over the detail, 2026-11-12 walk-through).
    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            VStack(spacing: Tokens.Spacing.s) {
                Picker("", selection: $status) { ForEach(StatusFilter.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                HStack {
                    clientPicker
                    hideEmptyToggle("빈 세션 숨기기").fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Picker("상태", selection: $status) { ForEach(StatusFilter.allCases) { Text($0.label).tag($0) } }
                    .labelsHidden()
                clientPicker
                hideEmptyToggle("빈 세션 숨김")
            }
        }
        .padding(Tokens.Spacing.s)
    }

    private var clientPicker: some View {
        Picker("클라이언트", selection: $client) {
            Text("모든 클라이언트").tag("all")
            ForEach(Array(Set(records.map(\.client))).sorted(), id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
    }

    private func hideEmptyToggle(_ label: String) -> some View {
        Toggle(label, isOn: $hideEmpty)
            .toggleStyle(.checkbox)
            .font(Tokens.Font.meta)
            .lineLimit(1)
            .help("진행 중이 아니고 작업 내용이 없거나 (pending)인 세션을 숨깁니다")
    }

    private var filtered: [SessionRecord] {
        Self.filter(records, status: status, client: client, hideEmpty: hideEmpty)
    }

    static func filter(_ records: [SessionRecord], status: StatusFilter, client: String, hideEmpty: Bool) -> [SessionRecord] {
        records.filter {
            (status == .all || $0.status == status.rawValue) && (client == "all" || $0.client == client)
                && !(hideEmpty && $0.isEmpty)
        }
    }

    private func live(for record: SessionRecord) -> LiveSession? {
        workspace.liveness.sessions(of: barrack.id).first { $0.id == record.id }
    }

    /// With nothing picked (or the pick filtered out), the newest session
    /// fills the detail instead of an empty, narrow screen (2026-11-09
    /// feedback); it is not acknowledged as seen.
    private func selectNewestIfNone() {
        guard selection == nil || !filtered.contains(where: { $0.id == selection }) else { return }
        autoSelected = filtered.first?.id
        selection = autoSelected
    }

    private func takePending() {
        guard let wanted = workspace.pendingSessionID, records.contains(where: { $0.id == wanted }) else { return }
        workspace.pendingSessionID = nil
        status = .all
        client = "all"
        // A session asked for by name is shown even if it is empty.
        if records.first(where: { $0.id == wanted })?.isEmpty == true { hideEmpty = false }
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
            // One line each (full text on hover): text that wrapped as the
            // pane narrowed raised the window's minimum height in a loop
            // until AppKit aborted (UX-02).
            let title = detail.record.task.isEmpty ? detail.record.id : detail.record.task
            Text(title).font(Tokens.Font.title).lineLimit(1).truncationMode(.tail).help(title)
            Text("\(detail.record.client) · \(detail.record.started) → \(detail.record.ended) · \(detail.record.status)")
                .font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary).lineLimit(1)
            if !detail.record.continues.isEmpty && detail.record.continues != "(없음)" {
                Label("이어받음: \(detail.record.continues)", systemImage: "arrow.turn.down.right")
                    .font(Tokens.Font.meta).foregroundStyle(Tokens.teal).lineLimit(1)
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
            Text(detail.seal == .modified ? "종료 후 봉인된 기록이 바뀌었습니다." : "봉인을 검증할 수 없습니다.").lineLimit(1)
            Text("승인: 터미널에서 aib sessions seal \(detail.record.id)").foregroundStyle(Tokens.textSecondary).lineLimit(1)
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
                ForEach(SectionRow.rows(title, items)) { row in
                    Text(row.text).font(Tokens.Font.body).textSelection(.enabled)
                }
            }
        }
    }
}

/// A row of one section of a List. Ids must be unique across the whole List:
/// with per-section offsets (0, 1, 2 in every section) SwiftUI reused the
/// first section's rows, and Decisions / Wiki Extractions showed Log lines
/// (found in the README screenshots, 2026-11-04).
struct SectionRow: Identifiable, Equatable {
    let id: String
    let text: String

    static func rows(_ section: String, _ items: [String]) -> [SectionRow] {
        items.enumerated().map { SectionRow(id: "\(section)#\($0.offset)", text: $0.element) }
    }
}
