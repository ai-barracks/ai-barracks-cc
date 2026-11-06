import AppKit
import SwiftUI

/// LY-01: every view the split view hosts fits the share a minimum-size
/// window leaves its column. A view whose own minimum is larger makes the
/// split view's minimum swing between passes; AppKit then aborts in an
/// endless Update Constraints loop (crash 2026-11-06 10:15, the Agents
/// bar) or leaves columns overlapping on resize. Runs in a probe child
/// (no window, no activation needed).
@MainActor
enum LayoutProbe {
    static func failures() -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-layout-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("wiki/topics"), withIntermediateDirectories: true)
        try? "# Rules\n\n## Must Always\n- a\n\n## Must Never\n\n## Learned\n".write(
            to: directory.appendingPathComponent("RULES.md"), atomically: true, encoding: .utf8)
        let barrack = Barrack(name: "layout-probe-barrack-with-a-long-name", path: directory.path,
                              description: "A barrack whose description is long enough to wrap in the sidebar and the info panel")
        let workspace = WorkspaceModel(barracks: [barrack], daemon: nil)
        workspace.selectedBarrackID = barrack.id
        let artifacts = ArtifactStore()
        var failures: [String] = []
        let verbose = ProcessInfo.processInfo.environment["AIBCC_PROBE_VERBOSE"] == "1"
        let check = { (name: String, width: CGFloat, limit: CGFloat) in
            if verbose { FileHandle.standardError.write(Data("\(name): \(Int(width.rounded()))pt (limit \(Int(limit)))\n".utf8)) }
            if width > limit + 0.5 { failures.append("\(name) needs \(Int(width.rounded()))pt > \(Int(limit))pt") }
        }
        // A minimum-size window's content area below the toolbar.
        let contentHeight = AppConstants.Layout.minWindowHeight - AppConstants.Layout.toolbarAllowance
        for destination in Destination.allCases {
            workspace.destination = destination
            check("center/\(destination.rawValue)", minimumWidth(CenterView(workspace: workspace, artifacts: artifacts)),
                  AppConstants.Layout.detailMinWidth)
            check("center/\(destination.rawValue) height",
                  minimumHeight(CenterView(workspace: workspace, artifacts: artifacts), width: AppConstants.Layout.detailMinWidth),
                  contentHeight)
        }
        check("inspector height", minimumHeight(InspectorView(workspace: workspace, artifacts: artifacts),
                                                width: AppConstants.Layout.inspectorMinWidth), contentHeight)
        check("sidebar height", minimumHeight(BarrackSidebar(workspace: workspace), width: AppConstants.Layout.sidebarMinWidth),
              contentHeight)
        workspace.destination = .sessions
        check("inspector", minimumWidth(InspectorView(workspace: workspace, artifacts: artifacts)), AppConstants.Layout.inspectorMinWidth)
        check("sidebar", minimumWidth(BarrackSidebar(workspace: workspace)), AppConstants.Layout.sidebarMinWidth)
        let window = AppConstants.Layout.sidebarMinWidth + AppConstants.Layout.detailMinWidth + AppConstants.Layout.inspectorMinWidth
        if window > AppConstants.Layout.minWindowWidth { failures.append("columns need \(Int(window))pt > window minimum") }
        return failures
    }

    /// The height a view takes at `width` when offered almost none.
    static func minimumHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let controller = NSHostingController(rootView: view.frame(width: width))
        return controller.sizeThatFits(in: NSSize(width: width, height: 1)).height
    }

    /// The width a view takes when offered almost none: its minimum.
    static func minimumWidth<V: View>(_ view: V) -> CGFloat {
        let controller = NSHostingController(rootView: view.frame(height: AppConstants.Layout.minWindowHeight))
        return controller.sizeThatFits(in: NSSize(width: 1, height: AppConstants.Layout.minWindowHeight)).width
    }
}
