import SwiftUI

/// Settings → v1에서 가져오기: find, show, then apply.
struct V1ImportSection: View {
    let workspace: WorkspaceModel
    @State private var found: V1SettingsImport.Found?
    @State private var applied: [String]?

    var body: some View {
        Section("v1에서 가져오기") {
            if let applied {
                Text(applied.isEmpty ? "가져올 새 항목이 없었습니다." : "가져옴: " + applied.joined(separator: " · "))
                    .font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
            } else if let found {
                if found.isEmpty {
                    Text("v1(CommandCenter 1.x)에 저장된 Quick Commands·터미널 설정·모델 프로필이 없습니다.")
                        .font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
                } else {
                    Text(summary(found)).font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
                    Button("가져오기") { applied = V1SettingsImport.apply(found, quickCommands: workspace.quickCommands) }
                }
            } else {
                Button("v1 설정 찾기") { found = V1SettingsImport.find() }
            }
            Text("예약 활성화는 v1과 같은 설정 파일을 써서 가져올 필요가 없습니다.")
                .font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
        }
    }

    private func summary(_ found: V1SettingsImport.Found) -> String {
        var parts: [String] = []
        if !found.quickCommands.isEmpty { parts.append("Quick Commands \(found.quickCommands.count)개") }
        if let size = found.fontSize { parts.append("글꼴 \(Int(size))pt") }
        if let cursor = found.cursor { parts.append("커서 \(cursor)") }
        parts += found.profiles.map { "\($0.key.label): \(ProviderProfiles.summary($0.value))" }
        return "찾음: " + parts.joined(separator: " · ")
    }
}
