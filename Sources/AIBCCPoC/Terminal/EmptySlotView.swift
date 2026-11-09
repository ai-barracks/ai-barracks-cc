import SwiftUI

/// A grid slot with no terminal (2026-11-10 feedback: a shell started by
/// default got in the way). Offers what the Agents bar offers; the buttons
/// stack when the slot is narrow so the slot never asks for more width
/// than a minimum window leaves it (LY-01).
struct EmptySlotView: View {
    let workspace: WorkspaceModel
    /// The whole grid is empty (not one free slot beside others).
    let isOnly: Bool
    @AppStorage(AppConstants.Terminal.skipPermissionsKey) private var skipPermissions = false

    var body: some View {
        VStack(spacing: Tokens.Spacing.m) {
            Image(systemName: "terminal")
                .font(.system(size: isOnly ? 30 : 20, weight: .light))
                .foregroundStyle(Tokens.textTertiary)
            Text(isOnly ? "에이전트나 터미널을 시작하세요" : "빈 칸")
                .font(isOnly ? Tokens.Font.body.weight(.semibold) : Tokens.Font.meta)
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(1)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tokens.Spacing.s) { buttons }
                VStack(spacing: Tokens.Spacing.s) { buttons }
            }
            .controlSize(isOnly ? .regular : .small)
            .disabled(workspace.selectedBarrack == nil)
        }
        .padding(Tokens.Spacing.m)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(Tokens.work)
    }

    @ViewBuilder private var buttons: some View {
        ForEach([AgentClient.claude, .codex, .gemini]) { client in
            Button(client.label) { _ = workspace.launchAgent(client, skipPermissions: skipPermissions) }
                .help("aib start \(client.rawValue)\(skipPermissions ? " --skip-permissions" : "")")
        }
        Button("Terminal") { _ = workspace.launchAgent(.terminal, skipPermissions: false) }
            .help("로그인 셸")
    }
}
