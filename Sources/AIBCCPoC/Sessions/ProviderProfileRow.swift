import SwiftUI

/// One client's model profile in Settings (v1 ProviderModels): model
/// (typed or picked from the advertised list), effort, save.
struct ProviderProfileRow: View {
    let client: AgentClient
    @State private var profile = ProviderProfile()
    @State private var models: [ProviderModel] = []
    @State private var source = ""
    @State private var busy = false
    @State private var message: String?

    private var efforts: [String] {
        models.first { $0.model == profile.model }.map(\.efforts).flatMap { $0.isEmpty ? nil : $0 } ?? ProviderProfiles.efforts(for: client)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack {
                Text(client == .codex ? "Codex" : "Claude Code").font(Tokens.Font.bodyMedium)
                Spacer()
                Button(busy ? "조회 중…" : "모델 목록 조회", action: fetch).disabled(busy)
            }
            HStack {
                TextField("모델", text: $profile.model, prompt: Text("비우면 CLI 기본 모델")).monospaced()
                if !models.isEmpty {
                    Menu("목록") {
                        ForEach(models) { model in
                            Button(model.isDefault ? "\(model.name) (기본)" : model.name) { profile.model = model.model; profile.effort = "" }
                        }
                    }
                    .fixedSize()
                }
            }
            Picker("Reasoning effort", selection: $profile.effort) {
                Text("CLI 기본").tag("")
                ForEach(efforts, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                if let message { Text(message).font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary).lineLimit(2) }
                Spacer()
                Button("저장") {
                    message = ProviderProfiles.save(profile, for: client) ? "저장됨 — 다음 새 세션부터" : "모델 이름이 너무 길거나 쓸 수 없는 문자가 있습니다"
                }
            }
            if !source.isEmpty { Text(source).font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary) }
        }
        .onAppear { profile = ProviderProfiles.load(client) }
    }

    private func fetch() {
        message = nil
        guard client == .codex else {
            models = ProviderProfiles.claudeAliases.map { ProviderModel(model: $0, name: $0, efforts: [], isDefault: false) }
            source = "문서상 Claude Code alias — 계정에서 쓸 수 있는지는 보장하지 않습니다"
            return
        }
        busy = true
        Task {
            defer { busy = false }
            guard let binary = await CodexModelProbe.findBinary() else { return message = "codex CLI를 찾지 못했습니다" }
            switch await CodexModelProbe.list(binary: binary) {
            case let .success(found):
                models = found
                source = "설치된 Codex app-server의 model/list (모델 요청 없음) · \(found.count)개"
            case let .failure(failure):
                message = failure.message
            }
        }
    }
}
