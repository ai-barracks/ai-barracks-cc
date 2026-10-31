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
/// SwiftUI never tears a terminal down because the layout changed.
struct TerminalGridView: View {
    let panes: [TerminalPane]
    let layout: PaneLayout

    var body: some View {
        PaneGridLayout(layout: layout, spacing: AppConstants.Layout.paneSpacing) {
            ForEach(panes) { pane in
                TerminalPaneView(pane: pane, state: pane.state)
            }
        }
        .background(Color(nsColor: .separatorColor))
    }
}

/// Places the first `layout.paneCount` panes in an equal grid and parks the
/// rest outside the visible area (their surfaces stop drawing, see
/// `WorkspaceModel.setLayout`).
struct PaneGridLayout: Layout {
    let layout: PaneLayout
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let frames = Self.frames(for: layout, in: bounds, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            if frames.indices.contains(index) {
                subview.place(at: frames[index].origin, proposal: ProposedViewSize(frames[index].size))
            } else {
                let parked = CGPoint(x: bounds.maxX + bounds.width + 1000, y: bounds.minY)
                subview.place(at: parked, proposal: ProposedViewSize(bounds.size))
            }
        }
    }

    static func frames(for layout: PaneLayout, in bounds: CGRect, spacing: CGFloat) -> [CGRect] {
        let halfWidth = (bounds.width - spacing) / 2
        let halfHeight = (bounds.height - spacing) / 2
        let rightX = bounds.minX + halfWidth + spacing
        let lowerY = bounds.minY + halfHeight + spacing
        switch layout {
        case .single:
            return [bounds]
        case .double:
            return [
                CGRect(x: bounds.minX, y: bounds.minY, width: halfWidth, height: bounds.height),
                CGRect(x: rightX, y: bounds.minY, width: halfWidth, height: bounds.height),
            ]
        case .quad:
            return [
                CGRect(x: bounds.minX, y: bounds.minY, width: halfWidth, height: halfHeight),
                CGRect(x: rightX, y: bounds.minY, width: halfWidth, height: halfHeight),
                CGRect(x: bounds.minX, y: lowerY, width: halfWidth, height: halfHeight),
                CGRect(x: rightX, y: lowerY, width: halfWidth, height: halfHeight),
            ]
        }
    }
}
