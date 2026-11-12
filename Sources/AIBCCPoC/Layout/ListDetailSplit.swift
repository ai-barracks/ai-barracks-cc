import AppKit
import SwiftUI

/// A list column the user widens or narrows by dragging its edge, and a
/// detail taking the rest of the width. Each screen remembers its own list
/// width. Built like OutputsColumn (plain frames and a drag handle, no
/// split view) so it takes no part in AppKit's column negotiation, which
/// once looped until the app aborted at the minimum window (UX-02).
/// (2026-11-09 feedback: lists stayed narrow and the detail did not use a
/// wide window.)
struct ListDetailSplit<ListContent: View, Detail: View>: View {
    @AppStorage private var stored: Double
    @State private var dragStart: Double?
    private let list: ListContent
    private let detail: Detail
    /// Hiding the list keeps the detail's place in the view tree, so a
    /// terminal grid is not rebuilt (and does not lose keyboard focus).
    private let showsList: Bool
    /// Width the detail keeps while the list can still give way: the list
    /// narrows to its minimum for it (a minimum window with Outputs open
    /// left a reader about 150pt and its toolbar ran under the next panel,
    /// 2026-11-12 walk-through).
    private let detailMinWidth: CGFloat
    /// The list goes away rather than squeeze the detail below its minimum
    /// (the agent list beside the terminals, LY-02b).
    private let foldsList: Bool

    init(widthKey: String, defaultWidth: CGFloat, showsList: Bool = true,
         detailMinWidth: CGFloat = AppConstants.Documents.detailMinWidth, foldsList: Bool = false,
         @ViewBuilder list: () -> ListContent, @ViewBuilder detail: () -> Detail) {
        _stored = AppStorage(wrappedValue: Double(defaultWidth), widthKey)
        self.showsList = showsList
        self.detailMinWidth = detailMinWidth
        self.foldsList = foldsList
        self.list = list()
        self.detail = detail()
    }

    var body: some View {
        GeometryReader { proxy in
            let shown = Self.width(stored: stored, available: proxy.size.width, detailMin: detailMinWidth)
            let fits = proxy.size.width - detailMinWidth >= AppConstants.Documents.listMinWidth
            HStack(spacing: 0) {
                if showsList, fits || !foldsList {
                    list.frame(width: shown).clipped()
                    handle(shown, available: proxy.size.width)
                }
                // Clipped: content with a fixed width must not draw over
                // the panel beside this one.
                detail.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            }
        }
    }

    /// At least the list minimum; at most its share of the width and what
    /// leaves the detail its minimum.
    static func width(stored: Double, available: CGFloat, detailMin: CGFloat = 0) -> CGFloat {
        let most = max(AppConstants.Documents.listMinWidth,
                       min(available * AppConstants.Documents.listMaxShare, available - detailMin))
        return min(max(CGFloat(stored), AppConstants.Documents.listMinWidth), most)
    }

    private func handle(_ shown: CGFloat, available: CGFloat) -> some View {
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
                                stored = Double(Self.width(stored: start + Double(drag.translation.width), available: available, detailMin: detailMinWidth))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
    }
}
