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
    /// Width the detail always keeps; the list folds away when it cannot
    /// fit beside it (terminals at a minimum window, LY-02b).
    private let detailMinWidth: CGFloat

    init(widthKey: String, defaultWidth: CGFloat, showsList: Bool = true, detailMinWidth: CGFloat = 0,
         @ViewBuilder list: () -> ListContent, @ViewBuilder detail: () -> Detail) {
        _stored = AppStorage(wrappedValue: Double(defaultWidth), widthKey)
        self.showsList = showsList
        self.detailMinWidth = detailMinWidth
        self.list = list()
        self.detail = detail()
    }

    var body: some View {
        GeometryReader { proxy in
            let room = proxy.size.width - detailMinWidth
            let shown = min(Self.width(stored: stored, available: proxy.size.width), room)
            HStack(spacing: 0) {
                if showsList, room >= AppConstants.Documents.listMinWidth {
                    list.frame(width: shown)
                    handle(shown, available: proxy.size.width)
                }
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// At least the list minimum; at most what leaves the detail its share.
    static func width(stored: Double, available: CGFloat) -> CGFloat {
        let most = max(AppConstants.Documents.listMinWidth, available * AppConstants.Documents.listMaxShare)
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
                                stored = Double(Self.width(stored: start + Double(drag.translation.width), available: available))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
    }
}
