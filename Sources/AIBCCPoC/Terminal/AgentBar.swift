import SwiftUI

/// Top of the Agents destination (v1 SessionsTab "New Agent"): start an
/// agent in one click. The barrack's terminals are listed beside the grid
/// (AgentListView), not here.
struct AgentBar: View {
    let workspace: WorkspaceModel
    @AppStorage(AppConstants.Terminal.skipPermissionsKey) private var skipPermissions = false
    @AppStorage(AppConstants.Terminal.agentListShownKey) private var listShown = true

    var body: some View {
        // Scrolls sideways instead of widening the column: a fixed row raised
        // the split view's minimum past what a narrow window leaves it, and
        // AppKit aborted in an endless constraint pass (crash 2026-11-06 10:15).
        ScrollView(.horizontal, showsIndicators: false) { launchRow }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Tokens.Spacing.m)
            .padding(.vertical, Tokens.Spacing.s)
            .background(.bar)
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
                .help("로그인 셸")
            Button("Council") { workspace.isCouncilSheetPresented = true }
                .help("aib council")
            Divider().frame(height: 14)
            Toggle("skip-permissions", isOn: $skipPermissions)
                .toggleStyle(.checkbox)
                .font(Tokens.Font.meta)
                .help("Claude·Codex·Gemini를 권한 확인 없이 시작 (--skip-permissions)")
            Divider().frame(height: 14)
            Toggle(isOn: $listShown) { Label("에이전트 목록", systemImage: "sidebar.left") }
                .toggleStyle(.button)
                .help("터미널 옆에 이 배럭의 에이전트 목록(상태·작업·위치)을 보이거나 숨깁니다")
        }
        .controlSize(.small)
        .disabled(workspace.selectedBarrack == nil)
    }
}
