import SwiftUI

/// Right inspector: Outputs, the barrack's recent documents next to the
/// terminals (spec §4, P1). The barrack's info and status moved to the
/// Barrack destination (user feedback 2026-11-06).
struct InspectorView: View {
    @Bindable var workspace: WorkspaceModel
    let artifacts: ArtifactStore

    var body: some View {
        VStack(spacing: 0) {
            Text("Outputs")
                .font(Tokens.Font.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Tokens.Spacing.m)
                .padding(.vertical, Tokens.Spacing.s)
            Divider()
            ArtifactPanel(store: artifacts)
        }
    }
}

/// Where you are and what runs there: barrack facts (v1 Overview) and
/// live sessions.
struct BarrackInfoPanel: View {
    let workspace: WorkspaceModel
    var changes = 0
    @State private var overview = BarrackOverview()

    var body: some View {
        if let barrack = workspace.selectedBarrack {
            List {
                Section("배럭") {
                    LabeledContent("이름", value: barrack.name)
                    LabeledContent("경로") { Text(barrack.path).lineLimit(2).truncationMode(.middle) }
                    if let description = barrack.description { Text(description).foregroundStyle(Tokens.textSecondary) }
                }
                overviewSections(barrack)
                Section("세션 (\(workspace.liveness.sessions(of: barrack.id).count))") {
                    ForEach(workspace.liveness.sessions(of: barrack.id)) { session in
                        HStack(spacing: Tokens.Spacing.s) {
                            LivenessBeacon(state: session.state)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(session.id).font(Tokens.Font.meta).lineLimit(1).truncationMode(.middle)
                                Text("\(session.state.label) · pid \(session.pid)")
                                    .font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
                            }
                        }
                    }
                }
            }
            .font(Tokens.Font.body)
            .task(id: "\(barrack.id)-\(changes)") { overview = await Task.detached { BarrackOverview.load(barrack.url) }.value }
        } else {
            ContentUnavailableView("배럭을 선택하세요", systemImage: "sidebar.left")
        }
    }

    @ViewBuilder
    private func overviewSections(_ barrack: Barrack) -> some View {
        Section("개요") {
            LabeledContent("세션 기록", value: "\(overview.sessions)")
            LabeledContent("Wiki 토픽", value: "\(overview.wikiTopics)")
            LabeledContent("규칙", value: "\(overview.ruleCount) (A \(overview.rules.mustAlways.count) · N \(overview.rules.mustNever.count) · L \(overview.rules.learned.count))")
            LabeledContent("Skills", value: "\(overview.skills)")
        }
        Section("정체성 (SOUL)") {
            if !overview.soul.name.isEmpty { Text(overview.soul.name).font(Tokens.Font.bodyMedium) }
            if !overview.soul.expertise.isEmpty { Text(overview.soul.expertise.joined(separator: " · ")).foregroundStyle(Tokens.textSecondary) }
            if !overview.soul.personality.isEmpty {
                Text(overview.soul.personality.joined(separator: " · ")).font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
            }
        }
        Section("agent.yaml") {
            if !overview.agent.primaryModel.isEmpty { LabeledContent("모델", value: overview.agent.primaryModel) }
            if !overview.agent.fallbackModels.isEmpty { LabeledContent("대체", value: overview.agent.fallbackModels.joined(separator: ", ")) }
            let cli = workspace.health?.cliVersion ?? ""
            LabeledContent("aib_version") {
                Text(overview.agent.aibVersion.isEmpty ? "—" : "v\(overview.agent.aibVersion)")
                    .foregroundStyle(overview.isOutdated(cliVersion: cli) ? Tokens.orange : Tokens.textSecondary)
            }
            if overview.isOutdated(cliVersion: cli) {
                Button("v\(cli)로 Sync (dry-run 후 Enter로 적용)") {
                    workspace.runInPane(title: "Sync - \(barrack.name)", command: MaintenanceScanner.confirmThenApply("aib sync --dry-run .", "aib sync ."))
                }
            }
        }
    }
}
