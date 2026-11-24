import AppKit
import SwiftUI

/// Pane presets agreed in Council 20261031_144814 (Focus, split, 2x2) plus
/// v1's top/bottom split (Codex parity audit P02). Free docking is out of
/// scope. Saved by name; `paneCount` is how many slots it shows.
enum PaneLayout: String, CaseIterable, Identifiable, Sendable {
    case single
    /// Left and right.
    case double
    /// Top and bottom.
    case twoRows
    case quad

    var id: String { rawValue }

    var paneCount: Int {
        switch self {
        case .single: 1
        case .double, .twoRows: 2
        case .quad: 4
        }
    }

    /// What a grid grows or shrinks through by itself; the top/bottom split
    /// is only ever the user's choice, and kept while it fits.
    static let growth: [PaneLayout] = [.single, .double, .quad]

    /// Layouts saved before names were (1, 2, 4).
    init?(slots: Int) {
        guard let layout = Self.growth.first(where: { $0.paneCount == slots }) else { return nil }
        self = layout
    }

    /// A saved grid's layout: by name; a record from before names, or a
    /// name this build does not know, by slot count; else one pane. Every
    /// attached session is kept either way (extra ones are parked).
    static func restored(name: String?, slots: Int) -> PaneLayout {
        name.flatMap(PaneLayout.init(rawValue:)) ?? PaneLayout(slots: slots) ?? .single
    }

    /// The layout that shows `count` slots: `current` when it already shows
    /// exactly that many (a top/bottom split stays one), else the smallest
    /// growth preset that does.
    static func fitting(_ count: Int, keeping current: PaneLayout) -> PaneLayout {
        current.paneCount == count ? current : growth.first { $0.paneCount >= count } ?? .quad
    }

    var label: String {
        switch self {
        case .single: "1"
        case .double: "2"
        case .twoRows: "3"
        case .quad: "4"
        }
    }

    var title: String {
        switch self {
        case .single: "터미널 1개"
        case .double: "좌우 2분할"
        case .twoRows: "상하 2분할"
        case .quad: "터미널 4개"
        }
    }

    var symbol: String {
        switch self {
        case .single: "rectangle"
        case .double: "rectangle.split.2x1"
        case .twoRows: "rectangle.split.1x2"
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
                    // Slots no terminal fills offer the start buttons instead
                    // of a shell started on the user's behalf.
                    ForEach(0 ..< max(0, workspace.layout.paneCount - workspace.panes.count), id: \.self) { _ in
                        EmptySlotView(workspace: workspace, isOnly: workspace.panes.isEmpty)
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
        if workspace.layout == .double || workspace.layout == .quad, size.width > 0 {
            DividerHandle(cursor: .resizeLeftRight)
                .frame(width: AppConstants.Layout.dividerHitWidth, height: size.height)
                .position(x: size.width * workspace.splitX, y: size.height / 2)
                .gesture(drag { workspace.setSplit(x: $0.x / size.width) })
        }
        if workspace.layout == .quad || workspace.layout == .twoRows, size.height > 0 {
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
        case .twoRows:
            return [
                CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: topHeight),
                CGRect(x: bounds.minX, y: lowerY, width: bounds.width, height: bottomHeight),
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

/// Where a terminal goes in a barrack's list (Codex parity audit P01, v1's
/// terminal list apart from its display slots): the first `paneCount`
/// panes show, the rest are held off screen and keep running. There is no
/// cap on how many a barrack holds (2026-11-12 report: a fifth agent could
/// not be started).
enum PanePlacement {
    /// A new pane: an empty slot if there is one; else it takes the focused
    /// slot (the last one when none is) and that pane moves off screen,
    /// first in line to come back. The layout is the user's: a new pane
    /// never splits the view (2026-11-13 feedback: the split a second agent
    /// forced narrowed the first one's screen, and what an agent has
    /// already printed stays that narrow).
    static func adding<T: Identifiable>(_ new: T, to panes: [T], layout: PaneLayout, focused: Int?) -> [T] {
        let slots = layout.paneCount
        guard panes.count >= slots else { return panes + [new] }
        let slot = focused.flatMap { $0 < slots ? $0 : nil } ?? slots - 1
        var shown = Array(panes.prefix(slots))
        let displaced = shown[slot]
        shown[slot] = new
        return shown + [displaced] + Array(panes.dropFirst(slots))
    }

    /// Shows `id` in `slot`: a pane already on screen trades places with the
    /// one there; a held one comes in and the slot's pane goes off screen
    /// in its place.
    /// Without `id`: the terminals still on screen keep their slots, and
    /// the first held one takes the freed slot.
    static func removing<T: Identifiable>(_ id: T.ID, from panes: [T], layout: PaneLayout) -> [T] {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return panes }
        var remaining = panes
        remaining.remove(at: index)
        let slots = layout.paneCount
        guard index < slots, remaining.count >= slots else { return remaining }
        let promoted = remaining.remove(at: slots - 1)
        remaining.insert(promoted, at: index)
        return remaining
    }

    static func showing<T: Identifiable>(_ id: T.ID, inSlot slot: Int, of panes: [T], layout: PaneLayout) -> [T] {
        guard let from = panes.firstIndex(where: { $0.id == id }), slot < min(layout.paneCount, panes.count), from != slot
        else { return panes }
        var result = panes
        result.swapAt(from, slot)
        return result
    }
}
