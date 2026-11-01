import SwiftUI

/// ⌘N sheet (spec §7): client → options → Enter.
struct NewAgentSheet: View {
    let workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var client: AgentClient = .claude
    @State private var skipPermissions = false
    @State private var full = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            Text("새 에이전트").font(Tokens.Font.title)
            Text(workspace.selectedBarrack.map { "\($0.name) 배럭에서 시작" } ?? "배럭을 먼저 선택하세요")
                .font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
            Picker("클라이언트", selection: $client) {
                ForEach(AgentClient.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Toggle("권한 확인 건너뛰기 (--skip-permissions)", isOn: $skipPermissions)
                .disabled(client == .terminal)
                .font(Tokens.Font.body)
            if full {
                Text("터미널 4개가 모두 사용 중입니다. pane 하나를 닫거나 다른 배럭에서 시작하세요.")
                    .font(Tokens.Font.meta).foregroundStyle(Tokens.orange)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("시작") {
                    if workspace.launchAgent(client, skipPermissions: skipPermissions) != nil { dismiss() } else { full = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(workspace.selectedBarrack == nil)
            }
        }
        .padding(Tokens.Spacing.l * 1.5)
        .frame(width: 420)
    }
}
