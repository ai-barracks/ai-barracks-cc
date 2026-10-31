import GhosttyTerminal
import SwiftUI

/// A terminal surface with a thin header. The surface itself is opaque —
/// Liquid Glass is reserved for navigation chrome (Council decision).
struct TerminalPaneView: View {
    let pane: TerminalPane
    @ObservedObject var state: TerminalViewState
    let onRestart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            TerminalSurfaceView(context: state)
                .overlay(alignment: .bottom) {
                    if pane.hasExited { exitBanner }
                }
        }
        .onChange(of: state.surfaceSize) { pane.startExitMonitorIfNeeded() }
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
            Text(displayTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let size = state.surfaceSize {
                Text("\(size.columns)×\(size.rows)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var exitBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "stop.circle")
            Text("프로세스 종료됨 — 출력은 그대로 남아 있습니다")
            Spacer(minLength: 8)
            Button("새 셸", action: onRestart)
                .controlSize(.small)
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
