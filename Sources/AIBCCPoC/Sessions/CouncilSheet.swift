import SwiftUI

/// ⌘⇧C (spec §7): topic → rounds → run. The debate runs in a pane;
/// its minutes land in resources/council and open in the Council viewer.
struct CouncilSheet: View {
    let workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var topic = ""
    @State private var rounds = 2

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            Text("Council 시작").font(Tokens.Font.title)
            Text("Claude와 Codex가 같은 주제를 토론하고 합의안을 냅니다. 토큰 비용이 큽니다.")
                .font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
            TextField("주제", text: $topic, axis: .vertical).lineLimit(2...4)
            Stepper("라운드 \(rounds)", value: $rounds, in: 1...4)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("시작") {
                    workspace.runInPane(title: "council", command: CouncilCommand.make(topic: topic, rounds: rounds))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.selectedBarrack == nil)
            }
        }
        .padding(Tokens.Spacing.l * 1.5)
        .frame(width: 460)
    }
}

enum CouncilCommand {
    static func make(topic: String, rounds: Int, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let output = "resources/council/\(formatter.string(from: now))-council.md"
        let cleaned = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        return "mkdir -p resources/council && aib council -r \(rounds) -o \(output) \(AgentLauncher.shellQuote(cleaned))"
    }
}
