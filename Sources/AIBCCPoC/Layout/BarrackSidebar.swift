import AppKit
import SwiftUI

/// Left column (spec §4): Attention summary → barracks in fixed registry
/// order (never reordered by alerts) → the selected barrack's destinations.
struct BarrackSidebar: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        List(selection: Binding(get: { workspace.selectedBarrackID },
                                set: { next in
                                    // Re-selecting where the user is asks nothing.
                                    guard next != workspace.selectedBarrackID else { return }
                                    workspace.navigate { workspace.selectedBarrackID = next }
                                })) {
            AttentionSummary(attention: workspace.liveness.attentionCount, running: workspace.liveness.runningCount)
                .listRowSeparator(.hidden)
                .selectionDisabled()
            Section {
                ForEach(workspace.barracks) { barrack in
                    BarrackRow(barrack: barrack, liveness: workspace.liveness)
                        .tag(barrack.id)
                        .contextMenu {
                            Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([barrack.url]) }
                            Divider()
                            Button("목록에서 제거…") { workspace.barrackToRemove = barrack }
                        }
                }
            } header: {
                HStack {
                    Text("배럭")
                    Spacer()
                    Menu {
                        Button("배럭 추가…") { workspace.isAddBarrackPresented = true }
                        Button("목록 새로 고침 (aib barracks refresh)") { workspace.refreshBarracks() }
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("배럭 추가·새로 고침")
                }
            }
            if let barrack = workspace.selectedBarrack {
                Section(barrack.name) {
                    ForEach(Destination.allCases) { destination in
                        DestinationRow(destination: destination, isOn: workspace.destination == destination,
                                       count: count(for: destination, barrack)) {
                            if workspace.destination != destination {
                                workspace.navigate { workspace.destination = destination }
                            }
                        }
                        .selectionDisabled()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if workspace.barracks.isEmpty {
                ContentUnavailableView {
                    Label("등록된 배럭 없음", systemImage: "tray")
                } description: {
                    Text("폴더를 골라 aib init으로 배럭을 만드세요")
                } actions: {
                    Button("배럭 추가…") { workspace.isAddBarrackPresented = true }
                }
            }
        }
        .sheet(isPresented: $workspace.isAddBarrackPresented) { AddBarrackSheet(workspace: workspace) }
        .confirmationDialog(removeTitle, isPresented: Binding(get: { workspace.barrackToRemove != nil },
                                                             set: { if !$0 { workspace.barrackToRemove = nil } })) {
            Button("목록에서 제거", role: .destructive) { workspace.removeConfirmedBarrack() }
        } message: {
            Text("aib barracks remove — 파일은 지우지 않고 ~/.aib/barracks.json 목록에서만 뺍니다. 다시 추가하면 돌아옵니다.")
        }
    }

    private var removeTitle: String {
        "\(workspace.barrackToRemove?.name ?? "") 배럭을 목록에서 뺄까요?"
    }

    private func count(for destination: Destination, _ barrack: Barrack) -> Int? {
        switch destination {
        case .barrack:
            let items = workspace.maintenance.items(for: barrack).count
            return items > 0 ? items : nil
        case .sessions:
            let running = workspace.liveness.sessions(of: barrack.id).filter { $0.state.isRunning }.count
            return running > 0 ? running : nil
        case .wiki:
            let topics = try? FileManager.default.contentsOfDirectory(atPath: barrack.url.appendingPathComponent("wiki/topics").path)
            return topics?.filter { $0.hasSuffix(".md") }.count
        case .skills:
            let count = BarrackDocuments.skills(in: barrack.url).count
            return count > 0 ? count : nil
        case .council:
            let count = BarrackDocuments.councilMinutes(in: barrack.url).count
            return count > 0 ? count : nil
        case .history:
            let count = SessionRecords.count(barrackPath: barrack.path)
            return count > 0 ? count : nil
        case .rules, .git:
            return nil
        }
    }
}

/// "주의 N · 실행 M" — the one line that says whether anything needs you.
private struct AttentionSummary: View {
    let attention: Int
    let running: Int

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Image(systemName: attention > 0 ? "exclamationmark.circle.fill" : "checkmark.circle")
                .foregroundStyle(attention > 0 ? Tokens.orange : Tokens.textTertiary)
            Text(attention > 0 ? "주의 \(attention)" : "주의 없음")
                .fontWeight(attention > 0 ? .semibold : .regular)
                .foregroundStyle(attention > 0 ? Tokens.orange : Tokens.textSecondary)
            Text("· 실행 \(running)").foregroundStyle(Tokens.textSecondary)
            Spacer()
        }
        .font(Tokens.Font.body)
        .padding(.horizontal, Tokens.Spacing.s)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.card)
                .fill(attention > 0 ? Tokens.orange.opacity(0.12) : Color.primary.opacity(0.04))
        )
    }
}

private struct BarrackRow: View {
    let barrack: Barrack
    let liveness: LivenessStore

    var body: some View {
        let headline = liveness.headline(of: barrack.id)
        let sessions = liveness.sessions(of: barrack.id)
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            LivenessBeacon(state: headline)
            VStack(alignment: .leading, spacing: 1) {
                Text(barrack.name).font(Tokens.Font.bodyMedium)
                Text(subtitle(headline, sessions))
                    .font(Tokens.Font.meta)
                    .foregroundStyle(headline.needsAttention ? headline.tint : Tokens.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            let running = sessions.filter { $0.state.isRunning }.count
            if running > 0 {
                Text("\(running)").font(Tokens.Font.numeric).foregroundStyle(Tokens.textSecondary)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 2)
        .overlay {
            if headline.needsAttention {
                RoundedRectangle(cornerRadius: Tokens.Radius.row).stroke(headline.tint.opacity(0.8), lineWidth: 1)
                    .padding(-3)
            }
        }
        .help(sessions.map { "\($0.id) · \($0.state.label) · \($0.ageSeconds)초 전 · pid \($0.pid)" }.joined(separator: "\n"))
    }

    private func subtitle(_ headline: Liveness, _ sessions: [LiveSession]) -> String {
        if headline.needsAttention, let session = sessions.first(where: { $0.state == headline && $0.needsAttention }) {
            return "\(headline.label) · \(Self.age(session.ageSeconds))"
        }
        return barrack.description ?? ""
    }

    static func age(_ seconds: Int) -> String {
        seconds < 60 ? "방금" : seconds < 3600 ? "\(seconds / 60)분" : seconds < 86_400 ? "\(seconds / 3600)시간" : "\(seconds / 86_400)일"
    }
}

private struct DestinationRow: View {
    let destination: Destination
    let isOn: Bool
    let count: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(destination.label, systemImage: destination.symbol)
                Spacer()
                if let count { Text("\(count)").font(Tokens.Font.numeric).foregroundStyle(Tokens.textSecondary) }
            }
            .foregroundStyle(isOn ? Tokens.textPrimary : Tokens.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.row).fill(isOn ? Tokens.teal.opacity(0.16) : .clear))
    }
}

/// The liveness beacon (spec §3): shape + color, never color alone.
struct LivenessBeacon: View {
    let state: Liveness

    var body: some View {
        Group {
            switch state {
            case .done:
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(state.tint)
            case .workingStale:
                Circle().stroke(state.tint, lineWidth: 1.5)
            case .interrupted:
                Circle().stroke(state.tint, style: StrokeStyle(lineWidth: 1.5, dash: [2, 1.5]))
            default:
                Circle().fill(state.tint)
            }
        }
        .frame(width: 7, height: 7)
        .accessibilityLabel(state.label)
    }
}

extension Liveness {
    var tint: Color {
        switch self {
        case .working, .workingStale: Tokens.teal
        case .blocked: Tokens.orange
        case .crashed: Tokens.red
        case .done: Tokens.green
        case .interrupted, .idle, .none: Tokens.idle
        }
    }
}
