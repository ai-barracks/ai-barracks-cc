import AppKit
import SwiftUI

/// Pane presets agreed in Council 20261031_144814: Focus, split, 2x2.
/// Free docking is intentionally out of scope.
enum PaneLayout: Int, CaseIterable, Identifiable, Sendable {
    case single = 1
    case double = 2
    case quad = 4

    var id: Int { rawValue }
    var paneCount: Int { rawValue }

    var label: String {
        switch self {
        case .single: "1"
        case .double: "2"
        case .quad: "4"
        }
    }

    var symbol: String {
        switch self {
        case .single: "rectangle"
        case .double: "rectangle.split.2x1"
        case .quad: "rectangle.split.2x2"
        }
    }
}

/// Every pane stays in one `ForEach`, so switching presets only moves views:
/// SwiftUI never tears a terminal down because the layout changed. Split
/// positions are dragged with overlay dividers (RS-03).
struct TerminalGridView: View {
    let workspace: WorkspaceModel

    static let coordinateSpaceName = "terminal-grid"

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                PaneGridLayout(
                    layout: workspace.layout,
                    splitX: workspace.splitX,
                    splitY: workspace.splitY,
                    spacing: AppConstants.Layout.paneSpacing
                ) {
                    ForEach(workspace.panes) { pane in
                        TerminalPaneView(pane: pane, state: pane.state, workspace: workspace) {
                            workspace.restartPane(id: pane.id)
                        }
                    }
                }
                dividers(in: proxy.size)
            }
            .coordinateSpace(name: Self.coordinateSpaceName)
        }
        .background(Color(nsColor: .separatorColor))
    }

    @ViewBuilder
    private func dividers(in size: CGSize) -> some View {
        if workspace.layout != .single, size.width > 0 {
            DividerHandle(cursor: .resizeLeftRight)
                .frame(width: AppConstants.Layout.dividerHitWidth, height: size.height)
                .position(x: size.width * workspace.splitX, y: size.height / 2)
                .gesture(drag { workspace.setSplit(x: $0.x / size.width) })
        }
        if workspace.layout == .quad, size.height > 0 {
            DividerHandle(cursor: .resizeUpDown)
                .frame(width: size.width, height: AppConstants.Layout.dividerHitWidth)
                .position(x: size.width / 2, y: size.height * workspace.splitY)
                .gesture(drag { workspace.setSplit(y: $0.y / size.height) })
        }
    }

    private func drag(_ update: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { update($0.location) }
    }
}

/// Invisible, hit-testable strip over a pane boundary.
private struct DividerHandle: View {
    let cursor: NSCursor

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { cursor.push() } else { NSCursor.pop() }
            }
    }
}

/// Places the first `layout.paneCount` panes in a grid split at
/// (`splitX`, `splitY`) and parks the rest outside the visible area (their
/// surfaces stop drawing, see `WorkspaceModel.updateSurfaceVisibility`).
struct PaneGridLayout: Layout {
    let layout: PaneLayout
    let splitX: CGFloat
    let splitY: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let slots = paneFrames(in: bounds)
        for (index, subview) in subviews.enumerated() {
            if slots.indices.contains(index) {
                subview.place(at: slots[index].origin, proposal: ProposedViewSize(slots[index].size))
            } else {
                let parked = CGPoint(x: bounds.maxX + bounds.width + 1000, y: bounds.minY)
                subview.place(at: parked, proposal: ProposedViewSize(bounds.size))
            }
        }
    }

    func paneFrames(in bounds: CGRect) -> [CGRect] {
        let leftWidth = ((bounds.width - spacing) * splitX).rounded()
        let rightWidth = bounds.width - spacing - leftWidth
        let topHeight = ((bounds.height - spacing) * splitY).rounded()
        let bottomHeight = bounds.height - spacing - topHeight
        let rightX = bounds.minX + leftWidth + spacing
        let lowerY = bounds.minY + topHeight + spacing
        switch layout {
        case .single:
            return [bounds]
        case .double:
            return [
                CGRect(x: bounds.minX, y: bounds.minY, width: leftWidth, height: bounds.height),
                CGRect(x: rightX, y: bounds.minY, width: rightWidth, height: bounds.height),
            ]
        case .quad:
            return [
                CGRect(x: bounds.minX, y: bounds.minY, width: leftWidth, height: topHeight),
                CGRect(x: rightX, y: bounds.minY, width: rightWidth, height: topHeight),
                CGRect(x: bounds.minX, y: lowerY, width: leftWidth, height: bottomHeight),
                CGRect(x: rightX, y: lowerY, width: rightWidth, height: bottomHeight),
            ]
        }
    }
}
