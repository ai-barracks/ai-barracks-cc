import AppKit
import SwiftUI

/// "배럭 추가" (v1 System → create barrack): pick or type a folder, see
/// what `aib init` will create there, run it.
struct AddBarrackSheet: View {
    let workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var running = false
    @State private var result: BarrackAdmin.Outcome?

    private var expanded: String { (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }
    private var isExistingBarrack: Bool { FileManager.default.fileExists(atPath: expanded + "/agent.yaml") }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Text("배럭 추가").font(.headline)
            HStack {
                TextField("폴더 경로", text: $path, prompt: Text("~/Develop/my_barrack")).textFieldStyle(.roundedBorder).monospaced()
                Button("폴더 선택…", action: choose)
            }
            Text(isExistingBarrack ? "이미 배럭인 폴더입니다(agent.yaml 있음) — 없는 파일만 만들고 목록에 등록합니다."
                 : "aib init·sync가 이 폴더에 없는 파일을 만듭니다(있는 파일은 건너뜀): \(BarrackAdmin.scaffold)")
                .font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
            Text("aib init은 Claude Code·Gemini CLI의 세션 hook 설정(~/.claude/settings.json 등)도 확인해 없으면 추가합니다.")
                .font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
            if let result {
                ScrollView {
                    Text(result.output.isEmpty ? (result.ok ? "완료" : "실패") : result.output)
                        .font(.system(size: 11).monospaced()).foregroundStyle(result.ok ? Tokens.textSecondary : Tokens.red)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            HStack {
                Spacer()
                Button(result?.ok == true ? "닫기" : "취소") { dismiss() }.keyboardShortcut(.cancelAction)
                if result?.ok != true {
                    Button(running ? "만드는 중…" : "aib init + sync 실행", action: create)
                        .disabled(running || path.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 560)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "선택"
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }

    private func create() {
        running = true
        let target = expanded
        Task {
            let outcome = await BarrackAdmin.create(at: target)
            result = outcome
            running = false
            if outcome.ok { workspace.registryChanged(select: target) }
        }
    }
}
