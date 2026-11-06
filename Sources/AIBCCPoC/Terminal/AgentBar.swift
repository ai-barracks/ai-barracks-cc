import GhosttyTerminal
import SwiftUI

/// Top of the Agents destination (v1 SessionsTab: "New Agent" + Live
/// Terminals): start an agent in one click, and see and switch the
/// barrack's terminals with their agent state.
struct AgentBar: View {
    let workspace: WorkspaceModel
    @AppStorage(AppConstants.Terminal.skipPermissionsKey) private var skipPermissions = false
    @State private var closing: TerminalPane?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            launchRow
            if !workspace.panes.isEmpty { chips }
        }
        .padding(.horizontal, Tokens.Spacing.m)
        .padding(.vertical, Tokens.Spacing.s)
        .background(.bar)
        .confirmationDialog(closing.map { "\($0.title) 닫기" } ?? "", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
            Button("닫기", role: .destructive) {
                if let pane = closing { workspace.closePane(id: pane.id) }
                closing = nil
            }
        } message: {
            Text("실행 중인 프로그램이 종료됩니다. 출력은 기록 → 터미널 출력에 보관됩니다.")
        }
    }

    private var launchRow: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Text("New Agent")
                .font(Tokens.Font.meta.weight(.semibold))
                .foregroundStyle(Tokens.textSecondary)
            ForEach([AgentClient.claude, .codex, .gemini]) { client in
                Button(client.label) { _ = workspace.launchAgent(client, skipPermissions: skipPermissions) }
                    .help("aib start \(client.rawValue)\(skipPermissions ? " --skip-permissions" : "")")
            }
            Divider().frame(height: 14)
            Button("Terminal") { _ = workspace.launchAgent(.terminal, skipPermissions: false) }
            Button("Council") { workspace.isCouncilSheetPresented = true }
            Spacer(minLength: Tokens.Spacing.s)
            if isFull {
                Text("터미널 \(PaneLayout.quad.paneCount)개 사용 중 — 하나를 닫으면 새로 시작할 수 있습니다")
                    .font(Tokens.Font.meta)
                    .foregroundStyle(Tokens.orange)
                    .lineLimit(1)
            }
            Toggle("skip-permissions", isOn: $skipPermissions)
                .toggleStyle(.checkbox)
                .font(Tokens.Font.meta)
                .help("Claude·Codex·Gemini를 권한 확인 없이 시작 (--skip-permissions)")
        }
        .controlSize(.small)
        .disabled(workspace.selectedBarrack == nil)
    }

    private var isFull: Bool { workspace.panes.count >= PaneLayout.quad.paneCount }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Spacing.s) {
                ForEach(Array(workspace.panes.enumerated()), id: \.element.id) { index, pane in
                    AgentChip(pane: pane, state: pane.state, liveness: workspace.liveness(of: pane),
                              isShown: index < workspace.layout.paneCount,
                              select: { workspace.selectPane(id: pane.id) },
                              close: { pane.hasExited ? workspace.closePane(id: pane.id) : (closing = pane) })
                }
            }
        }
    }
}

/// One terminal of the barrack: state dot, title, what its agent is doing.
private struct AgentChip: View {
    let pane: TerminalPane
    @ObservedObject var state: TerminalViewState
    let liveness: Liveness?
    let isShown: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            Text(pane.title)
                .font(Tokens.Font.meta.weight(.medium))
                .strikethrough(pane.hasExited)
                .lineLimit(1)
            if let status {
                Text(status).font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary).lineLimit(1)
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("터미널 닫기")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(state.isFocused ? Color.accentColor.opacity(0.14) : Tokens.panel))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(state.isFocused ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.25),
                              style: StrokeStyle(lineWidth: 1, dash: isShown ? [] : [3, 2]))
        )
        .opacity(pane.hasExited ? 0.6 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(perform: select)
        .help(isShown ? "이 터미널로 이동" : "화면에 없는 터미널 — 누르면 앞으로 가져옵니다")
    }

    private var status: String? {
        if pane.hasExited { return "종료됨" }
        return liveness?.label
    }

    private var dotColor: Color {
        if pane.hasExited { return .secondary.opacity(0.5) }
        switch liveness {
        case .blocked?: return Tokens.orange
        case .crashed?, .interrupted?: return Tokens.red
        case .done?, .idle?: return Tokens.green
        case .working?, .workingStale?: return Tokens.teal
        default: return .secondary
        }
    }
}
