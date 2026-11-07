import SwiftUI

/// 정비 tab: only what needs a decision. Each item expands to its evidence
/// and runs its command in a new terminal pane (dry run first).
struct MaintenancePanel: View {
    let workspace: WorkspaceModel
    let store: MaintenanceStore

    var body: some View {
        let barrack = workspace.selectedBarrack
        let items = store.items(for: barrack)
        let scanning = store.isScanning(barrack)
        VStack(spacing: 0) {
            HStack {
                Text(scanning ? "점검 중…" : items.isEmpty ? "판단할 항목 없음" : "판단 필요 \(items.count)")
                    .font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
                Spacer()
                Button { Task { await store.scan(barrack) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(scanning).help("다시 점검")
            }
            .padding(Tokens.Spacing.s)
            List(items) { item in
                MaintenanceRow(item: item) {
                    // Only items found in the barrack the command will run in.
                    guard let barrack, store.items(for: barrack).contains(item) else { return }
                    workspace.runInPane(title: item.title, command: item.command)
                }
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

/// The latest scan's items, tied to the barrack they were found in. A scan
/// started meanwhile — another barrack, or a refresh — supersedes an
/// earlier one, whose late result is dropped; nothing is shown or run for
/// a barrack other than the one it came from (Codex build-84 review F1: a
/// switch during a scan left the old barrack's items, runnable, on the
/// new one, and the new barrack's scan request was dropped).
@MainActor
@Observable
final class MaintenanceStore {
    typealias Scanner = @Sendable (Barrack) async -> [MaintenanceItem]

    private var items: [MaintenanceItem] = []
    /// Whose `items` these are.
    private(set) var barrackID: Barrack.ID?
    private var scanningID: Barrack.ID?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let scanner: Scanner

    init(scanner: @escaping Scanner = { await MaintenanceScanner.scan(barrack: $0) }) {
        self.scanner = scanner
    }

    /// Items found in `barrack`; none while another barrack's are held.
    func items(for barrack: Barrack?) -> [MaintenanceItem] {
        barrack != nil && barrack?.id == barrackID ? items : []
    }

    func isScanning(_ barrack: Barrack?) -> Bool {
        barrack != nil && barrack?.id == scanningID
    }

    func scan(_ barrack: Barrack?) async {
        guard let barrack else { return }
        generation += 1
        let request = generation
        if barrackID != barrack.id {
            items = []
            barrackID = barrack.id
        }
        scanningID = barrack.id
        let found = await scanner(barrack)
        guard request == generation else { return }
        items = found
        scanningID = nil
    }
}
