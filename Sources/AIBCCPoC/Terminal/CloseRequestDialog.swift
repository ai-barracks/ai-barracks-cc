import SwiftUI

/// Closing a running terminal asks first (agent list X). An agent is offered
/// "정리하고 닫기": its session-end protocol runs before it goes, which X
/// alone never gives it a turn for (2026-11-24, measured).
struct CloseRequestDialog: ViewModifier {
    let workspace: WorkspaceModel

    func body(content: Content) -> some View {
        content.confirmationDialog(workspace.closeRequest.map { "\($0.title) 닫기" } ?? "",
                                   isPresented: Binding(get: { workspace.closeRequest != nil },
                                                        set: { if !$0 { workspace.closeRequest = nil } })) {
            if let pane = workspace.closeRequest {
                if workspace.isAgent(pane) {
                    Button("정리하고 닫기") { workspace.startWrapUp(of: pane) }
                    Button("바로 닫기", role: .destructive) { workspace.closePane(id: pane.id) }
                } else {
                    Button("닫기", role: .destructive) { workspace.closePane(id: pane.id) }
                }
            }
        } message: {
            Text(message)
        }
    }

    private var message: String {
        let archive = "출력은 History → 터미널 출력에 보관됩니다."
        guard let pane = workspace.closeRequest, workspace.isAgent(pane) else {
            return "실행 중인 프로그램이 종료됩니다. " + archive
        }
        return "정리하고 닫기(⌘⇧W): 에이전트에게 세션 종료 절차(기록 마무리·위키 정리)를 요청하고, 그 턴이 끝나면 닫습니다.\n"
            + "바로 닫기: 정리 없이 종료합니다. aib 세션 기록은 닫히지만 위키·Wiki Extractions 정리는 빠집니다.\n" + archive
    }
}
