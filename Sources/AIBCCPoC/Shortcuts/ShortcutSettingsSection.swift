import SwiftUI

/// Settings → 단축키: every action's key, changed by pressing a new one.
struct ShortcutSettingsSection: View {
    private let store = ShortcutStore.shared
    @State private var recording: ShortcutAction?
    @State private var problems: [ShortcutAction: String] = [:]

    var body: some View {
        ForEach(ShortcutAction.Group.allCases) { group in
            Section {
                ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                    row(action)
                }
            } header: {
                Text("단축키 · \(group.rawValue)")
            } footer: {
                if group == ShortcutAction.Group.allCases.last {
                    HStack(alignment: .top) {
                        Text("오른쪽 칸을 누른 뒤 새 조합을 누르세요(⌘ 포함, Esc는 취소). 한/영 입력 상태와 관계없이 키 위치로 동작합니다.")
                            .font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
                        Spacer()
                        Button("모두 기본값으로") { stopRecording(); problems = [:]; store.resetAll() }
                            .disabled(store.overrides.isEmpty)
                    }
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    private func row(_ action: ShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(action.title)
                Spacer()
                Button(recording == action ? "키를 누르세요…" : (store.chord(for: action)?.display ?? "없음")) {
                    record(action)
                }
                .monospaced()
                .frame(minWidth: 120)
                .help("눌러서 새 단축키 입력")
                Button { stopRecording(); problems[action] = nil; store.clear(action) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("단축키 없음")
                    .disabled(store.chord(for: action) == nil)
                Button {
                    stopRecording()
                    problems[action] = store.reset(action)?.message
                } label: { Image(systemName: "arrow.uturn.backward.circle") }
                    .buttonStyle(.borderless)
                    .help("기본값(\(action.defaultChord?.display ?? "없음"))으로")
                    .disabled(!store.isCustom(action))
            }
            if let problem = problems[action] {
                Text(problem).font(Tokens.Font.meta).foregroundStyle(Tokens.red)
            }
        }
    }

    private func record(_ action: ShortcutAction) {
        recording = action
        ShortcutCenter.recorder = { chord in
            recording = nil
            guard let chord else { return }
            problems[action] = store.assign(chord, to: action)?.message
        }
    }

    private func stopRecording() {
        recording = nil
        ShortcutCenter.recorder = nil
    }
}
