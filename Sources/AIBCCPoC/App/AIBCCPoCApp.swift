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
        // The terminal is the main work surface (P0): open wide enough for a
        // readable single pane next to the sidebar and the artifact panel.
        .defaultSize(width: AppConstants.Layout.defaultWindowWidth, height: AppConstants.Layout.defaultWindowHeight)
        .commands {
            // SwiftUI's default pasteboard items stay disabled when the first
            // responder is an AppKit view (the terminal), and a disabled
            // item still swallows its shortcut: Cmd+V never reached the
            // terminal (self-test IN-07, 2026-10-31). Forward to the first
            // responder instead — terminal or document viewer.
            CommandGroup(replacing: .pasteboard) {
                ResponderCommand(title: "잘라내기", selector: #selector(NSText.cut(_:)), key: "x")
                ResponderCommand(title: "복사하기", selector: #selector(NSText.copy(_:)), key: "c")
                ResponderCommand(title: "붙여넣기", selector: #selector(NSText.paste(_:)), key: "v")
                ResponderCommand(title: "전체 선택", selector: #selector(NSText.selectAll(_:)), key: "a")
            }
            CommandMenu("에이전트") {
                Button("새 에이전트…") { workspace.isNewAgentSheetPresented = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("다음 주의 항목으로") { workspace.goToNextAttention() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
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

/// Menu command that sends a standard action to the current first responder.
private struct ResponderCommand: View {
    let title: String
    let selector: Selector
    let key: KeyEquivalent

    var body: some View {
        Button(title) { NSApp.sendAction(selector, to: nil, from: nil) }
            .keyboardShortcut(key, modifiers: .command)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
}
