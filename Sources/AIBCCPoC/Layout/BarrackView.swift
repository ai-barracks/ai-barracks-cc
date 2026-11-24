import SwiftUI

/// The Barrack destination: what this barrack is (Info: facts, SOUL,
/// agent.yaml, live sessions) beside what it needs (Status: the
/// maintenance queue). Both were inspector tabs next to the terminals,
/// where they were rarely needed at the same time (user, 2026-11-06).
struct BarrackView: View {
    let workspace: WorkspaceModel
    var changes = 0

    var body: some View {
        // Side by side when there is room, stacked when not: fixed column
        // minimums would push the split view's minimum past a narrow
        // window's center (the constraint-loop crash of 2026-11-06).
        GeometryReader { proxy in
            if proxy.size.width >= AppConstants.Layout.barrackColumnsMinWidth {
                HStack(alignment: .top, spacing: 0) {
                    column("Info") { BarrackInfoPanel(workspace: workspace, changes: changes) }
                    Divider()
                    column("Status") { MaintenancePanel(workspace: workspace, store: workspace.maintenance) }
                }
            } else {
                VStack(spacing: 0) {
                    column("Info") { BarrackInfoPanel(workspace: workspace, changes: changes) }
                    Divider()
                    column("Status") { MaintenancePanel(workspace: workspace, store: workspace.maintenance) }
                }
            }
        }
        .background(Tokens.work)
    }

    private func column(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Tokens.Font.title)
                .padding(.horizontal, Tokens.Spacing.m)
                .padding(.vertical, Tokens.Spacing.s)
            Divider()
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
