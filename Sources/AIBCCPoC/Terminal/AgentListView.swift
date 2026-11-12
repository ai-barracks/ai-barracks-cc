import GhosttyTerminal
import SwiftUI

/// The barrack's terminals as a list beside the grid (v1 SessionsTab "Live
/// Terminals"; 2026-11-12 report: with several agents it was hard to see
/// which one was doing what and to switch). Each row says what runs there,
/// its state, the aib session's task, and where it shows; a click brings it
/// up (into the focused slot when it is off screen).
struct AgentListView: View {
    let workspace: WorkspaceModel
    @State private var closing: TerminalPane?
    /// Task lines by aib session id, read from the session files.
    @State private var tasks: [String: String] = [:]

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
                    ForEach(Array(workspace.panes.enumerated()), id: \.element.id) { index, pane in
                        let session = workspace.liveSession(of: pane)
                        AgentRow(pane: pane, state: pane.state, session: session,
                                 task: session.flatMap { tasks[$0.id] },
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
        // Session files fill in their task after the agent starts.
        .task(id: sessionIDs) {
            while !Task.isCancelled {
                readTasks()
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

    private func readTasks() {
        guard let barrack = workspace.selectedBarrack else { return }
        tasks = Dictionary(sessionIDs.compactMap { id in
            SessionRecords.detail(barrackPath: barrack.path, id: id).map { (id, $0.record.task) }
        }, uniquingKeysWith: { first, _ in first })
    }
}

/// One terminal: state dot, name, state and task, slot (or off screen).
private struct AgentRow: View {
    let pane: TerminalPane
    @ObservedObject var state: TerminalViewState
    let session: LiveSession?
    let task: String?
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
                if let task, !task.isEmpty, task != "(pending)" {
                    Text(task).font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary).lineLimit(2)
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
