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
    @AppStorage(AppConstants.Layout.outputsWidthKey) private var width = Double(AppConstants.Layout.inspectorIdealWidth)
    @State private var dragStart: Double?

    var body: some View {
        HStack(spacing: 0) {
            handle
            InspectorView(workspace: workspace, artifacts: artifacts)
                .frame(width: CGFloat(clamped(width)))
        }
    }

    private var handle: some View {
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
                                let start = dragStart ?? width
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
