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
            TerminalGridView(workspace: workspace)
                .inspector(isPresented: $workspace.isArtifactPanelVisible) {
                    ArtifactPanel(store: artifacts)
                        .inspectorColumnWidth(
                            min: AppConstants.Layout.inspectorMinWidth,
                            ideal: AppConstants.Layout.inspectorIdealWidth
                        )
                }
        }
        .toolbar { toolbarContent }
        .onChange(of: workspace.selectedBarrackID, initial: true) {
            artifacts.watch(root: workspace.selectedBarrack?.url)
        }
        .task {
            await SelfTestLauncher.runIfRequested(workspace: workspace, artifacts: artifacts)
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
