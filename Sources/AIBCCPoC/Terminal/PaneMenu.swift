import SwiftUI

/// Per-pane actions (v1 terminal tab bar parity): export output, save a
/// Quick Command, close the terminal.
struct PaneMenu: View {
    let pane: TerminalPane
    let workspace: WorkspaceModel

    var body: some View {
        Menu {
            Button("출력 내보내기") { workspace.exportOutput(of: pane) }
            Button("Quick Command 추가…") { workspace.quickCommandDraft = QuickCommand(label: "", command: "") }
            if !workspace.quickCommands.commands.isEmpty {
                Menu("Quick Command 실행") {
                    ForEach(workspace.quickCommands.commands) { quick in
                        Button(quick.label) { workspace.run(quick, in: pane) }
                    }
                }
            }
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

/// Add / manage Quick Commands.
struct QuickCommandSheet: View {
    let workspace: WorkspaceModel
    @State var draft: QuickCommand
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            Text("Quick Commands").font(Tokens.Font.title)
            TextField("이름 (비우면 명령)", text: $draft.label)
            TextField("명령", text: $draft.command).font(.system(size: 13).monospaced())
            HStack {
                Spacer()
                Button("추가") {
                    workspace.quickCommands.add(label: draft.label, command: draft.command)
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
                    }
                    Spacer()
                    Button(role: .destructive) { workspace.quickCommands.remove(quick.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            .frame(minHeight: 140)
            HStack { Spacer(); Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(Tokens.Spacing.l * 1.5)
        .frame(width: 480, height: 420)
    }
}
