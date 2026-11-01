import SwiftUI

/// 정비 tab: only what needs a decision. Each item expands to its evidence
/// and runs its command in a new terminal pane (dry run first).
struct MaintenancePanel: View {
    let workspace: WorkspaceModel
    let store: MaintenanceStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.isScanning ? "점검 중…" : store.items.isEmpty ? "판단할 항목 없음" : "판단 필요 \(store.items.count)")
                    .font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
                Spacer()
                Button { Task { await store.scan(workspace.selectedBarrack) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(store.isScanning).help("다시 점검")
            }
            .padding(Tokens.Spacing.s)
            List(store.items) { item in
                MaintenanceRow(item: item) { workspace.runInPane(title: item.title, command: item.command) }
            }
        }
        .task(id: workspace.selectedBarrackID) { await store.scan(workspace.selectedBarrack) }
    }
}

private struct MaintenanceRow: View {
    let item: MaintenanceItem
    let run: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(item.details.prefix(12).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 10.5).monospaced()).foregroundStyle(Tokens.textSecondary).lineLimit(2)
                }
                Button("터미널에서 실행", action: run).controlSize(.small).padding(.top, 4)
            }
        } label: {
            HStack {
                Image(systemName: "diamond").foregroundStyle(Tokens.orange)
                Text(item.title).font(Tokens.Font.body)
                Spacer()
                Text("\(item.count)").font(Tokens.Font.numeric).foregroundStyle(Tokens.textSecondary)
            }
        }
    }
}

@MainActor
@Observable
final class MaintenanceStore {
    private(set) var items: [MaintenanceItem] = []
    private(set) var isScanning = false

    func scan(_ barrack: Barrack?) async {
        guard let barrack, !isScanning else { return }
        isScanning = true
        items = await MaintenanceScanner.scan(barrack: barrack)
        isScanning = false
    }
}
