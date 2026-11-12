import GhosttyTerminal
import SwiftUI

/// The barrack's terminals as a list beside the grid (v1 SessionsTab "Live
/// Terminals"; 2026-11-12 report: with several agents it was hard to see
/// which one was doing what and to switch). Each row says what runs there,
/// its state, what its screen titles itself, the aib session's task and
/// newest log line, and where it shows; a click brings it up (into the
/// focused slot when it is off screen). Rows stay in start order: they do
/// not move when terminals trade slots (2026-11-13 feedback).
struct AgentListView: View {
    let workspace: WorkspaceModel
    @State private var closing: TerminalPane?
    /// Task and newest log line by aib session id, from the session files.
    @State private var work: [String: AgentWork] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("에이전트 \(workspace.panes.count)")
                    .font(Tokens.Font.meta.weight(.semibold)).foregroundStyle(Tokens.textSecondary)
                Spacer()
            }
            .padding(.horizontal, Tokens.Spacing.m)
            .padding(.vertical, Tokens.Spacing.s)
            // A plain stack, not a List: a table row click would take the
            // keyboard focus from the terminal, and the focused slot is
            // where an off-screen terminal is brought up.
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(workspace.panesByStart) { pane in
                        let session = workspace.liveSession(of: pane)
                        let index = workspace.panes.firstIndex { $0.id == pane.id } ?? Int.max
                        AgentRow(pane: pane, state: pane.state, session: session,
                                 work: session.flatMap { work[$0.id] },
                                 slot: index < workspace.layout.paneCount ? index + 1 : nil,
                                 close: { pane.hasExited ? workspace.closePane(id: pane.id) : (closing = pane) })
                            .contentShape(Rectangle())
                            .onTapGesture { workspace.selectPane(id: pane.id) }
                    }
                }
                .padding(.horizontal, Tokens.Spacing.s)
            }
        }
        .background(Tokens.work)
        // Session files change while the agent works: reread often, off
        // the main thread.
        .task(id: sessionIDs) {
            while !Task.isCancelled {
                await readWork()
                try? await Task.sleep(for: AppConstants.Terminal.agentTaskRefresh)
            }
        }
        .confirmationDialog(closing.map { "\($0.title) 닫기" } ?? "",
                            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
            Button("닫기", role: .destructive) {
                if let pane = closing { workspace.closePane(id: pane.id) }
                closing = nil
            }
        } message: {
            Text("실행 중인 프로그램이 종료됩니다. 출력은 History → 터미널 출력에 보관됩니다.")
        }
    }

    private var sessionIDs: [String] {
        workspace.panes.compactMap { workspace.liveSession(of: $0)?.id }
    }

    private func readWork() async {
        guard let path = workspace.selectedBarrack?.path else { return }
        let ids = sessionIDs
        let read = await Task.detached { AgentWork.read(barrackPath: path, sessions: ids) }.value
        if !Task.isCancelled, read != work { work = read }
    }
}

/// What an aib session file says the agent is on.
struct AgentWork: Equatable, Sendable {
    let task: String
    /// Newest `## Log` entry, if any.
    let latestLog: String?

    static func read(barrackPath: String, sessions: [String]) -> [String: AgentWork] {
        Dictionary(sessions.compactMap { id in
            SessionRecords.detail(barrackPath: barrackPath, id: id).map {
                (id, AgentWork(task: shown($0.record.task) ?? "", latestLog: $0.log.last.flatMap(shown)))
            }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Nil for the placeholders a new session file starts with.
    static func shown(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "(pending)" || trimmed == "(starting)" ? nil : trimmed
    }
}

/// One terminal: state dot, name, state and task, slot (or off screen).
private struct AgentRow: View {
    let pane: TerminalPane
    @ObservedObject var state: TerminalViewState
    let session: LiveSession?
    let work: AgentWork?
    /// 1-based slot, nil when held off screen.
    let slot: Int?
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.s) {
            Circle().fill(dotColor).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pane.title).font(Tokens.Font.body.weight(state.isFocused ? .semibold : .regular))
                        .strikethrough(pane.hasExited).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(slot.map { "칸 \($0)" } ?? "화면 밖")
                        .font(Tokens.Font.meta)
                        .foregroundStyle(slot == nil ? Tokens.orange : Tokens.textTertiary)
                }
                Text(status).font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary).lineLimit(1)
                // What the program titles its screen: the agent's own
                // one-line summary of what it is on, as it changes.
                if let screen = screenTitle {
                    Text(screen).font(Tokens.Font.meta).foregroundStyle(Tokens.textPrimary).lineLimit(2)
                }
                if let task = work?.task, !task.isEmpty {
                    Text(task).font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary).lineLimit(2)
                }
                if let log = work?.latestLog {
                    Text(log).font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary).lineLimit(2)
                }
            }
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.borderless)
                .help("터미널 닫기")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(state.isFocused ? Color.accentColor.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .opacity(pane.hasExited ? 0.6 : 1)
        .help(slot == nil ? "화면 밖에서 실행 중 — 누르면 지금 칸으로 가져옵니다" : "이 터미널로 이동")
    }

    private var status: String {
        if pane.hasExited { return "종료됨" }
        if let session { return session.state.label }
        if pane.agent != nil { return "시작 중" }
        return pane.userCommand ?? "셸"
    }

    private var screenTitle: String? {
        let title = state.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty || title == pane.title || pane.hasExited ? nil : title
    }

    private var dotColor: Color {
        if pane.hasExited { return .secondary.opacity(0.5) }
        switch session?.state {
        case .blocked?: return Tokens.orange
        case .crashed?, .interrupted?: return Tokens.red
        case .done?, .idle?: return Tokens.green
        case .working?, .workingStale?: return Tokens.teal
        default: return .secondary
        }
    }
}
