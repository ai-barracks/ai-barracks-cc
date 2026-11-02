import SwiftUI

/// Settings → 예약 활성화 (v1 ActivationSchedule): opt-in, which CLIs, the
/// next slot and the run history.
struct ActivationSettingsSection: View {
    let scheduler: ActivationScheduler?
    @State private var view = ActivationScheduler.View()
    @State private var message: String?

    var body: some View {
        Section {
            if let scheduler {
                Toggle("예약 활성화 켜기", isOn: binding(\.enabled, scheduler))
                    .disabled(!view.available && !view.config.enabled)
                HStack {
                    Toggle("Claude Code", isOn: binding(\.claude, scheduler))
                    Toggle("Codex", isOn: binding(\.codex, scheduler))
                }
                .toggleStyle(.checkbox)
                if let next = view.nextSlot {
                    LabeledContent("다음 실행", value: next.formatted(date: .abbreviated, time: .shortened))
                }
                if let error = view.error ?? message { Text(error).font(Tokens.Font.meta).foregroundStyle(Tokens.orange) }
                if !view.history.isEmpty {
                    DisclosureGroup("기록 \(view.history.count)") {
                        ForEach(Array(view.history.enumerated()), id: \.offset) { _, run in
                            Text("\(run.slot) · \(run.provider.label) · \(run.status) — \(run.detail)")
                                .font(Tokens.Font.meta).foregroundStyle(run.status == "success" ? Tokens.textSecondary : Tokens.orange)
                        }
                    }
                }
            } else {
                Text("자체 테스트 중에는 예약을 다루지 않습니다.").font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
            }
        } header: {
            Text("예약 활성화")
        } footer: {
            Text("매일 06·11·16·21시(KST)에 고른 CLI마다 \"OK\" 한 줄 요청을 구독 로그인으로 보냅니다(API 키 거부). 놓친 시간은 나중에 실행하지 않고, 실패해도 다시 시도하지 않습니다. v1 CommandCenter와 같은 설정·잠금을 써서 한 앱만 예약을 맡습니다.")
                .font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
        }
        .onAppear { if let scheduler { view = scheduler.view() } }
    }

    private func binding(_ key: WritableKeyPath<ActivationConfig, Bool>, _ scheduler: ActivationScheduler) -> Binding<Bool> {
        Binding(get: { view.config[keyPath: key] }, set: { value in
            var config = view.config
            config[keyPath: key] = value
            switch scheduler.save(config) {
            case let .success(updated):
                view = updated
                message = nil
            case let .failure(reason):
                message = reason.message
                view = scheduler.view()
            }
        })
    }
}
