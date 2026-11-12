import GhosttyTerminal
import SwiftUI

/// A terminal surface with a thin header. The surface itself is opaque —
/// Liquid Glass is reserved for navigation chrome (Council decision).
struct TerminalPaneView: View {
    let pane: TerminalPane
    @ObservedObject var state: TerminalViewState
    var workspace: WorkspaceModel?
    let onRestart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            TerminalSurfaceView(context: state)
                .overlay(alignment: .bottom) {
                    if pane.hasExited {
                        exitBanner
                    } else if let notice = pane.notice {
                        noticeBanner(notice)
                    }
                }
        }
        .onChange(of: state.surfaceSize) { pane.startExitMonitorIfNeeded() }
        .onChange(of: state.isFocused) { _, focused in if focused { workspace?.noteFocused(pane.id) } }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(state.isFocused ? Color.accentColor : Color.clear)
                .frame(height: 2)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            if let workspace, workspace.panes.count > 1, let slot = workspace.panes.firstIndex(where: { $0.id == pane.id }) {
                SlotPicker(workspace: workspace, slot: slot, title: displayTitle)
            } else {
                Text(displayTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            // A narrow slot drops the size before it squeezes the title.
            if let size = state.surfaceSize, size.columns >= AppConstants.Terminal.headerSizeMinColumns {
                Text("\(size.columns)×\(size.rows)")
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.secondary)
            }
            if let workspace { PaneMenu(pane: pane, workspace: workspace) }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var exitBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "stop.circle")
            Text(pane.failure.map { "세션을 이어받지 못함 — \($0)" } ?? "프로세스 종료됨 — 출력은 그대로 남아 있습니다")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button("새 셸", action: onRestart)
                .controlSize(.small)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }

    private var displayTitle: String {
        state.title.isEmpty ? pane.title : state.title
    }
}

/// The slot header's title as a menu of the barrack's terminals: picking
/// one shows it in this slot, and the one shown here takes its place
/// (P01 — more terminals than slots; 2026-11-12 report).
private struct SlotPicker: View {
    let workspace: WorkspaceModel
    let slot: Int
    let title: String

    var body: some View {
        Menu {
            Section("이 칸에 보일 터미널") {
                ForEach(Array(workspace.panes.enumerated()), id: \.element.id) { index, pane in
                    Button {
                        workspace.show(pane.id, inSlot: slot)
                    } label: {
                        if index == slot {
                            Label(pane.title, systemImage: "checkmark")
                        } else {
                            Text(index < workspace.layout.paneCount ? "\(pane.title) — 칸 \(index + 1)" : "\(pane.title) — 화면 밖")
                        }
                    }
                }
            }
        } label: {
            Text(title).lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .help("이 칸에 다른 터미널 보이기")
    }
}
