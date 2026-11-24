import AppKit
import SwiftUI

/// The Outputs panel as a plain right column of the detail, resized by
/// dragging its leading edge. It replaced SwiftUI's `.inspector`: inside a
/// NavigationSplitView, an inspector beside a document view on a window at
/// its minimum size kept renegotiating column sizes until AppKit aborted
/// ("more Update Constraints in Window passes than there are views",
/// UX-02, 2026-11-06). A fixed-width column takes no part in that.
struct OutputsColumn: View {
    @Bindable var workspace: WorkspaceModel
    let artifacts: ArtifactStore
    /// The detail column's width: the panel never takes the center's share.
    let available: CGFloat
    @AppStorage(AppConstants.Layout.outputsWidthKey) private var width = Double(AppConstants.Layout.inspectorIdealWidth)
    @State private var dragStart: Double?

    var body: some View {
        let shown = Self.width(stored: width, available: available)
        if shown > 0 {
            HStack(spacing: 0) {
                handle(shown)
                InspectorView(workspace: workspace, artifacts: artifacts)
                    .frame(width: shown)
            }
        }
    }

    /// What the panel may take: the user's width within its bounds, but
    /// never more than leaves `centerReserveWidth` to the terminals and the
    /// Agents bar; folded away (0) below `outputsFoldWidth` (Codex build-84
    /// review F2: a widened panel left a minimum window's terminal 8
    /// columns wide and hid the New Agent buttons).
    static func width(stored: Double, available: CGFloat) -> CGFloat {
        let preferred = CGFloat(min(max(stored, Double(AppConstants.Layout.inspectorMinWidth)), Double(AppConstants.Layout.outputsMaxWidth)))
        let room = available - AppConstants.Layout.centerReserveWidth
        let shown = min(preferred, room)
        return shown >= AppConstants.Layout.outputsFoldWidth ? shown : 0
    }

    private func handle(_ shown: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: AppConstants.Layout.dividerHitWidth)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = dragStart ?? Double(shown)
                                dragStart = start
                                width = clamped(start - Double(drag.translation.width))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, Double(AppConstants.Layout.inspectorMinWidth)), Double(AppConstants.Layout.outputsMaxWidth))
    }
}
