import SwiftUI

/// Thin 3-column skeleton: barracks (left) · terminal grid (center) ·
/// artifact .md viewer (right inspector, the user's preferred side).
struct MainView: View {
    @Bindable var workspace: WorkspaceModel
    let artifacts: ArtifactStore

    var body: some View {
        NavigationSplitView {
            BarrackSidebar(workspace: workspace)
                .navigationSplitViewColumnWidth(
                    min: AppConstants.Layout.sidebarMinWidth,
                    ideal: AppConstants.Layout.sidebarMinWidth + 40
                )
        } detail: {
            center
                .inspector(isPresented: $workspace.isArtifactPanelVisible) {
                    InspectorView(workspace: workspace, artifacts: artifacts)
                        .inspectorColumnWidth(
                            min: AppConstants.Layout.inspectorMinWidth,
                            ideal: AppConstants.Layout.inspectorIdealWidth
                        )
                }
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $workspace.isNewAgentSheetPresented) { NewAgentSheet(workspace: workspace) }
        .sheet(isPresented: $workspace.isCouncilSheetPresented) { CouncilSheet(workspace: workspace) }
        .sheet(isPresented: $workspace.isPalettePresented) { CommandPalette(workspace: workspace) }
        .overlay(alignment: .topTrailing) { ToastStack(workspace: workspace) }
        .navigationTitle(workspace.selectedBarrack?.name ?? "AIBCC")
        .navigationSubtitle(workspace.destination.label)
        .onChange(of: workspace.selectedBarrackID, initial: true) {
            artifacts.watch(root: workspace.selectedBarrack?.url)
        }
        .task {
            await SelfTestLauncher.runIfRequested(workspace: workspace, artifacts: artifacts)
        }
    }

    /// Terminals leave the hierarchy while a document is shown; panes keep
    /// their views and shells (same as a barrack switch, WS-01).
    @ViewBuilder
    private var center: some View {
        if workspace.destination == .sessions || workspace.selectedBarrack == nil {
            TerminalGridView(workspace: workspace)
        } else if let barrack = workspace.selectedBarrack, workspace.destination == .history {
            SessionHistoryView(workspace: workspace, barrack: barrack, changes: artifacts.fileEvents)
        } else if let barrack = workspace.selectedBarrack, workspace.destination == .git {
            GitView(workspace: workspace, barrack: barrack)
        } else if let barrack = workspace.selectedBarrack {
            DocumentView(barrack: barrack, destination: workspace.destination,
                         startCouncil: { workspace.isCouncilSheetPresented = true },
                         changes: artifacts.fileEvents,
                         pending: Binding(get: { workspace.pendingDocument }, set: { workspace.pendingDocument = $0 }))
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("레이아웃", selection: layoutBinding) {
                ForEach(PaneLayout.allCases) { preset in
                    Image(systemName: preset.symbol).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .help("터미널 분할")
            .disabled(workspace.destination != .sessions)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                workspace.isArtifactPanelVisible.toggle()
            } label: {
                Image(systemName: "doc.richtext")
            }
            .help("산출물 패널")
        }
    }

    private var layoutBinding: Binding<PaneLayout> {
        Binding(
            get: { workspace.layout },
            set: { workspace.setLayout($0) }
        )
    }
}
