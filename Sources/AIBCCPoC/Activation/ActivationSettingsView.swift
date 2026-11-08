import SwiftUI

/// What the 예약 활성화 section may do, apart from the view (v1
/// ActivationSchedule, Codex parity audit P11): turning ON asks first and
/// says what it costs, OFF stays reachable whenever it is on — even when
/// the schedule cannot be used — and the state is re-read while shown and
/// after a failed save.
@MainActor
@Observable
final class ActivationSettingsModel {
    typealias Load = @MainActor () -> ActivationScheduler.View
    typealias Save = @MainActor (ActivationConfig) -> Result<ActivationScheduler.View, ActivationFailure>

    private(set) var view = ActivationScheduler.View()
    private(set) var message: String?
    /// ON was asked for and waits for "자동 요청 활성화".
    private(set) var confirming = false
    @ObservationIgnored private let load: Load
    @ObservationIgnored private let save: Save

    init(load: @escaping Load, save: @escaping Save) {
        self.load = load
        self.save = save
    }

    convenience init(scheduler: ActivationScheduler) {
        self.init(load: { scheduler.view() }, save: { scheduler.save($0) })
    }

    var isOn: Bool { view.config.enabled }
    /// OFF never depends on availability; ON needs a usable schedule.
    var canSwitch: Bool { isOn || view.available }
    var canPickProviders: Bool { view.available }
    var hasProvider: Bool { view.config.claude || view.config.codex }
    var providers: String {
        [view.config.claude ? "Claude Code" : nil, view.config.codex ? "Codex" : nil].compactMap { $0 }.joined(separator: "·")
    }

    func refresh() {
        view = load()
    }

    /// The switch: OFF saves at once, ON only opens the confirmation.
    func requestSwitch(on: Bool) {
        guard on != isOn else { return }
        if on {
            guard view.available else { return }
            message = hasProvider ? nil : "CLI를 하나 이상 고르세요"
            confirming = hasProvider
        } else {
            confirming = false
            apply(with(\.enabled, false))
        }
    }

    func confirmEnable() {
        guard confirming else { return }
        confirming = false
        apply(with(\.enabled, true))
    }

    func cancelEnable() {
        confirming = false
    }

    func setProvider(_ key: WritableKeyPath<ActivationConfig, Bool>, _ value: Bool) {
        apply(with(key, value))
    }

    private func with(_ key: WritableKeyPath<ActivationConfig, Bool>, _ value: Bool) -> ActivationConfig {
        var config = view.config
        config[keyPath: key] = value
        return config
    }

    /// A failed save re-reads the real state: OFF may have taken effect in
    /// memory (and stopped a request) even when the file could not be written.
    private func apply(_ config: ActivationConfig) {
        switch save(config) {
        case let .success(updated):
            view = updated
            message = nil
        case let .failure(reason):
            view = load()
            message = reason.message
        }
    }
}

/// Settings → 예약 활성화 (v1 ActivationSchedule): opt-in, which CLIs, the
/// next slot and the run history.
struct ActivationSettingsSection: View {
    let scheduler: ActivationScheduler?
    @State private var model: ActivationSettingsModel?

    var body: some View {
        Section {
            if let model {
                ActivationControls(model: model)
            } else if scheduler == nil {
                Text("자체 테스트 중에는 예약을 다루지 않습니다.").font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
            }
        } header: {
            Text("예약 활성화")
        } footer: {
            Text("매일 06·11·16·21시(KST)에 고른 CLI마다 \"OK\" 한 줄 요청을 구독 로그인으로 보냅니다(API 키 거부, 격리된 임시 폴더·CLI 기본 모델). 앱과 Mac이 깨어 있을 때만 실행하고, 놓친 시간은 나중에 실행하지 않으며 실패해도 다시 시도하지 않습니다. 켜면 다음 예정 시각부터 시작합니다. v1 CommandCenter와 같은 설정·잠금을 써서 한 앱만 예약을 맡습니다.")
                .font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
        }
        .task(id: scheduler == nil) {
            guard let scheduler else { return }
            let model = self.model ?? ActivationSettingsModel(scheduler: scheduler)
            self.model = model
            // Re-read while shown (v1 polled every 5 s): another app may hold
            // the schedule, and runs add history.
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: AppConstants.Activation.settingsRefresh)
            }
        }
    }
}

private struct ActivationControls: View {
    let model: ActivationSettingsModel

    var body: some View {
        Toggle("예약 활성화 켜기", isOn: Binding(get: { model.isOn }, set: { model.requestSwitch(on: $0) }))
            .disabled(!model.canSwitch)
            .help(model.canSwitch ? "" : "예약을 쓸 수 없는 상태에서는 켤 수 없습니다")
            .confirmationDialog("실제 모델 요청을 예약할까요?",
                                isPresented: Binding(get: { model.confirming }, set: { if !$0 { model.cancelEnable() } })) {
                Button("자동 요청 활성화") { model.confirmEnable() }
                Button("취소", role: .cancel) { model.cancelEnable() }
            } message: {
                Text(confirmationText)
            }
        HStack {
            Toggle("Claude Code", isOn: Binding(get: { model.view.config.claude }, set: { model.setProvider(\.claude, $0) }))
            Toggle("Codex", isOn: Binding(get: { model.view.config.codex }, set: { model.setProvider(\.codex, $0) }))
        }
        .toggleStyle(.checkbox)
        .disabled(!model.canPickProviders)
        LabeledContent("다음 실행", value: model.view.nextSlot.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "꺼짐 — 예약된 요청 없음")
        if let error = model.view.error ?? model.message {
            Text(error).font(Tokens.Font.meta).foregroundStyle(Tokens.orange)
        }
        if !model.view.history.isEmpty {
            DisclosureGroup("기록 \(model.view.history.count)") {
                ForEach(Array(model.view.history.enumerated()), id: \.offset) { _, run in
                    Text("\(run.slot) · \(run.provider.label) · \(run.status) — \(run.detail)")
                        .font(Tokens.Font.meta).foregroundStyle(run.status == "success" ? Tokens.textSecondary : Tokens.orange)
                }
            }
        }
    }

    private var confirmationText: String {
        let next = ActivationSchedule.nextSlot(after: Date()).formatted(date: .abbreviated, time: .shortened)
        return "\(model.providers)에 매일 06·11·16·21시(KST)마다 사용자 개입 없이 \"OK\" 한 줄 요청을 보냅니다. CLI 한 번 실행에 제공자 내부 재시도가 포함될 수 있습니다. 요청은 사용량 한도를 소비하고 한도 초기화를 보장하지 않으며, 요금제에 따라 추가 사용량이 청구될 수 있습니다. OFF로 이후 요청은 멈추지만 이미 보낸 요청은 되돌릴 수 없습니다. 다음 실행 예정: \(next)."
    }
}
