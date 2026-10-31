import AppKit
import SwiftUI

@main
struct AIBCCPoCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var workspace = WorkspaceModel()
    @State private var artifacts = ArtifactStore()

    var body: some Scene {
        // Single window: panes own their native views, which cannot live in
        // two view hierarchies at once (Codex review r2 #10).
        Window("AIBCC Swift PoC", id: "main") {
            MainView(workspace: workspace, artifacts: artifacts)
                .frame(
                    minWidth: AppConstants.Layout.minWindowWidth,
                    minHeight: AppConstants.Layout.minWindowHeight
                )
        }
        .commands {
            CommandMenu("레이아웃") {
                ForEach(PaneLayout.allCases) { preset in
                    Button("터미널 \(preset.label)개") { workspace.setLayout(preset) }
                        .keyboardShortcut(KeyEquivalent(Character(preset.label)), modifiers: [.command, .option])
                }
                Divider()
                Button("산출물 패널 토글") { workspace.isArtifactPanelVisible.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Button("입력 호출 로그 저장 (IME fixture)") {
                    if let file = workspace.exportInputCallLogs() {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                }
                .keyboardShortcut("l", modifiers: [.command, .option, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
}
