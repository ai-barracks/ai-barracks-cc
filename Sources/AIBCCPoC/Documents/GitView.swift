import SwiftUI

/// Git destination (CC v1.6.1 parity: status, log, commit, push). Reading
/// is shown here; anything that changes the repo runs in a terminal pane.
struct GitView: View {
    let workspace: WorkspaceModel
    let barrack: Barrack
    @State private var status = ""
    @State private var log = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(spacing: Tokens.Spacing.s) {
                Button("변경 보기") { workspace.runInPane(title: "git diff", command: "git diff --stat && git diff") }
                Button("커밋…") { workspace.runInPane(title: "git commit", command: "git add -p && git commit") }
                Button("Push") { workspace.runInPane(title: "git push", command: "git push") }
                Spacer()
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }
            .controlSize(.small)
            section("상태", status)
            section("최근 커밋", log)
        }
        .padding(Tokens.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.work)
        .task(id: barrack.id) { await reload() }
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(title).font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
            ScrollView {
                Text(text.isEmpty ? "—" : text)
                    .font(.system(size: 12).monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
        }
    }

    private func reload() async {
        status = await GitReader.run(["status", "--short", "--branch"], in: barrack.path)
        log = await GitReader.run(["log", "--oneline", "--decorate", "-30"], in: barrack.path)
    }
}

enum GitReader {
    static func run(_ arguments: [String], in directory: String) async -> String {
        await ProcessOutput.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", directory] + arguments, in: directory)
    }
}
