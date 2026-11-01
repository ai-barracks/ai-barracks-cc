import SwiftUI

/// Right inspector (spec §4): 산출물 (P1, default) and 문맥.
struct InspectorView: View {
    @Bindable var workspace: WorkspaceModel
    let artifacts: ArtifactStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $workspace.inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    let count = tab == .maintenance ? workspace.maintenance.items.count : 0
                    Text(count > 0 ? "\(tab.label) \(count)" : tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Tokens.Spacing.s)
            Divider()
            switch workspace.inspectorTab {
            case .artifacts: ArtifactPanel(store: artifacts)
            case .context: ContextPanel(workspace: workspace)
            case .maintenance: MaintenancePanel(workspace: workspace, store: workspace.maintenance)
            }
        }
    }
}

/// Where you are and what runs there: barrack facts and live sessions.
private struct ContextPanel: View {
    let workspace: WorkspaceModel

    var body: some View {
        if let barrack = workspace.selectedBarrack {
            List {
                Section("배럭") {
                    LabeledContent("이름", value: barrack.name)
                    LabeledContent("경로") { Text(barrack.path).lineLimit(2).truncationMode(.middle) }
                    if let description = barrack.description { Text(description).foregroundStyle(Tokens.textSecondary) }
                }
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
        } else {
            ContentUnavailableView("배럭을 선택하세요", systemImage: "sidebar.left")
        }
    }
}
