import SwiftUI

/// Read-only barrack list in registry order (order never changes on alerts).
struct BarrackSidebar: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        List(selection: $workspace.selectedBarrackID) {
            Section("배럭") {
                ForEach(workspace.barracks) { barrack in
                    BarrackRow(barrack: barrack)
                        .tag(barrack.id)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if workspace.barracks.isEmpty {
                ContentUnavailableView(
                    "등록된 배럭 없음",
                    systemImage: "tray",
                    description: Text("aib init으로 배럭을 등록하세요")
                )
            }
        }
    }
}

private struct BarrackRow: View {
    let barrack: Barrack

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(barrack.name)
                .font(.system(size: 13, weight: .medium))
            if let description = barrack.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
