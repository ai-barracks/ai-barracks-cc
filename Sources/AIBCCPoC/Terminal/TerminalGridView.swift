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

struct TerminalGridView: View {
    let panes: [TerminalPane]
    let layout: PaneLayout

    var body: some View {
        switch layout {
        case .single:
            paneView(at: 0)
        case .double:
            HSplitView {
                paneView(at: 0)
                paneView(at: 1)
            }
        case .quad:
            VSplitView {
                HSplitView {
                    paneView(at: 0)
                    paneView(at: 1)
                }
                HSplitView {
                    paneView(at: 2)
                    paneView(at: 3)
                }
            }
        }
    }

    @ViewBuilder
    private func paneView(at index: Int) -> some View {
        if panes.indices.contains(index) {
            TerminalPaneView(pane: panes[index], state: panes[index].state)
                .id(panes[index].id)
        } else {
            Color.clear
        }
    }
}
