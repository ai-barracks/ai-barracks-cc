import SwiftUI

/// Per-pane actions (v1 terminal tab bar parity): export output, save a
/// Quick Command, close the terminal.
struct PaneMenu: View {
    let pane: TerminalPane
    let workspace: WorkspaceModel

    var body: some View {
        Menu {
            Button("출력 내보내기") { workspace.exportOutput(of: pane) }
            Button("Quick Command로 저장…") { workspace.saveDraft(from: pane) }
            if !workspace.quickCommands.commands.isEmpty {
                Menu("Quick Command 실행 (새 터미널)") {
                    ForEach(workspace.quickCommands.commands) { quick in
                        Button(quick.label) { workspace.run(quick) }
                    }
                }
                Menu("이 터미널에 입력") {
                    ForEach(workspace.quickCommands.commands) { quick in
                        Button(quick.label) { workspace.send(quick, to: pane) }
                    }
                }
                .disabled(workspace.isAgent(pane))
                .help(workspace.isAgent(pane) ? "에이전트 터미널에는 입력하지 않습니다" : "이 터미널에 명령을 입력하고 Enter")
            }
            Button("Quick Commands 관리…") { workspace.quickCommandDraft = QuickCommand(label: "", command: "") }
            Divider()
            Button("터미널 닫기", role: .destructive) { workspace.closePane(id: pane.id) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("터미널 동작")
    }
}

/// Toolbar list of the barrack's terminals (v1 LIVE TERMINALS): the
/// visible ones are checked; picking a hidden one brings it to the front.
struct TerminalListMenu: View {
    let workspace: WorkspaceModel

    var body: some View {
        Menu {
            ForEach(Array(workspace.panes.enumerated()), id: \.element.id) { index, pane in
                Button {
                    workspace.bringToFront(id: pane.id)
                } label: {
                    if index < workspace.layout.paneCount { Label(pane.title, systemImage: "checkmark") } else { Text(pane.title) }
                }
            }
        } label: {
            Label("터미널 \(workspace.panes.count)", systemImage: "rectangle.stack")
        }
        .help("이 배럭의 터미널")
    }
}

/// Add, edit and remove Quick Commands. A row loads into the form for
/// editing; the folder is optional (empty: the barrack's).
struct QuickCommandSheet: View {
    let workspace: WorkspaceModel
    @State var draft: QuickCommand
    @Environment(\.dismiss) private var dismiss

    private var isEditing: Bool { workspace.quickCommands.commands.contains { $0.id == draft.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            Text("Quick Commands").font(Tokens.Font.title)
            TextField("이름 (비우면 명령)", text: $draft.label)
            TextField("명령", text: $draft.command).font(.system(size: 13).monospaced())
            TextField("폴더 (비우면 배럭 폴더)", text: Binding(get: { draft.cwd ?? "" }, set: { draft.cwd = $0 }))
                .font(.system(size: 12).monospaced())
            HStack {
                Text("실행하면 이 폴더에서 새 터미널을 엽니다").font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
                Spacer()
                if isEditing { Button("새로 만들기") { draft = QuickCommand(label: "", command: "") } }
                Button(isEditing ? "저장" : "추가") {
                    workspace.quickCommands.upsert(draft)
                    draft = QuickCommand(label: "", command: "")
                }
                .disabled(draft.command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Divider()
            List(workspace.quickCommands.commands) { quick in
                HStack {
                    VStack(alignment: .leading) {
                        Text(quick.label).font(Tokens.Font.body)
                        Text(quick.command).font(.system(size: 11).monospaced()).foregroundStyle(Tokens.textTertiary)
                        if let folder = quick.cwd {
                            Text(folder).font(.system(size: 10).monospaced()).foregroundStyle(Tokens.textTertiary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Button(role: .destructive) { workspace.quickCommands.remove(quick.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
                .contentShape(Rectangle())
                .onTapGesture { draft = quick }
                .listRowBackground(quick.id == draft.id ? Color.accentColor.opacity(0.12) : Color.clear)
            }
            .frame(minHeight: 140)
            HStack { Spacer(); Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(Tokens.Spacing.l * 1.5)
        .frame(width: 520, height: 470)
    }
}

/// The questions a Quick Command may ask before running (P03): a saved
/// folder that is gone is never replaced silently, and typing into a
/// terminal whose program is unknown needs a yes.
struct QuickCommandPrompts: ViewModifier {
    @Bindable var workspace: WorkspaceModel

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(get: { workspace.quickCommandPrompt != nil },
                                               set: { if !$0 { workspace.quickCommandPrompt = nil } }),
                   presenting: workspace.quickCommandPrompt) { prompt in
                switch prompt {
                case let .missingFolder(quick):
                    Button("배럭 폴더에서 이번만 실행") { workspace.runInBarrackFolder(quick) }
                    // A sheet asked for while the alert is still closing is dropped.
                    Button("경로 수정") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + AppConstants.Layout.presentAfterAlert) {
                            workspace.quickCommandDraft = quick
                        }
                    }
                    Button("취소", role: .cancel) {}
                case let .confirmSend(quick, pane):
                    Button("입력") { _ = workspace.type(quick, into: pane) }
                    Button("취소", role: .cancel) {}
                }
            } message: { prompt in
                switch prompt {
                case let .missingFolder(quick):
                    Text("\(quick.cwd ?? "")\n폴더가 없습니다. 다른 위치에서 조용히 실행하지 않습니다.")
                case let .confirmSend(quick, pane):
                    Text("\(pane.title)에서 실행 중인 프로그램이 다음을 입력으로 받습니다:\n\(quick.command)")
                }
            }
    }

    private var title: String {
        switch workspace.quickCommandPrompt {
        case let .missingFolder(quick)?: "\(quick.label): 폴더 없음"
        case let .confirmSend(_, pane)?: "\(pane.title)에 입력할까요?"
        case nil: ""
        }
    }
}
