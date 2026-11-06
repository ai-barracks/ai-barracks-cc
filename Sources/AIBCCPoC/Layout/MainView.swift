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
        .alert("편집 중입니다", isPresented: Binding(get: { workspace.isConfirmingNavigation },
                                                set: { if !$0 { workspace.cancelNavigation() } })) {
            Button("편집 버리고 이동", role: .destructive) { workspace.confirmNavigation() }
            Button("계속 편집", role: .cancel) { workspace.cancelNavigation() }
        } message: {
            Text("저장하지 않은 편집이 있습니다.")
        }
        .sheet(isPresented: $workspace.isPalettePresented) { CommandPalette(workspace: workspace) }
        .overlay(alignment: .topTrailing) { ToastStack(workspace: workspace) }
        .sheet(item: $workspace.quickCommandDraft) { draft in QuickCommandSheet(workspace: workspace, draft: draft) }
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
            VStack(spacing: 0) {
                if workspace.selectedBarrack != nil {
                    AgentBar(workspace: workspace)
                    Divider()
                }
                TerminalGridView(workspace: workspace)
            }
        } else if let barrack = workspace.selectedBarrack, workspace.destination == .history {
            HistoryDestinationView(workspace: workspace, barrack: barrack, changes: artifacts.fileEvents)
        } else if let barrack = workspace.selectedBarrack, workspace.destination == .git {
            GitView(workspace: workspace, barrack: barrack, changes: artifacts.fileEvents)
        } else if let barrack = workspace.selectedBarrack, workspace.destination == .skills {
            SkillsView(barrack: barrack, changes: artifacts.fileEvents,
                       pending: Binding(get: { workspace.pendingDocument }, set: { workspace.pendingDocument = $0 }),
                       pendingEdit: Binding(get: { workspace.pendingStructuredEdit }, set: { workspace.pendingStructuredEdit = $0 }))
        } else if let barrack = workspace.selectedBarrack {
            DocumentView(barrack: barrack, destination: workspace.destination,
                         startCouncil: { workspace.isCouncilSheetPresented = true },
                         changes: artifacts.fileEvents,
                         pending: Binding(get: { workspace.pendingDocument }, set: { workspace.pendingDocument = $0 }),
                         pendingEdit: Binding(get: { workspace.pendingStructuredEdit }, set: { workspace.pendingStructuredEdit = $0 }),
                         editInProgress: Binding(get: { workspace.editInProgress }, set: { workspace.editInProgress = $0 }),
                         discardRevision: workspace.discardRevision)
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
            TerminalListMenu(workspace: workspace)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                workspace.isArtifactPanelVisible.toggle()
            } label: {
                Image(systemName: "doc.richtext")
            }
            .help("Outputs 패널")
        }
    }

    private var layoutBinding: Binding<PaneLayout> {
        Binding(
            get: { workspace.layout },
            set: { workspace.setLayout($0) }
        )
    }
}
