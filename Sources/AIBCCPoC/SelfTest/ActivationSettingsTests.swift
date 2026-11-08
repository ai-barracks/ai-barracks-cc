import Foundation

/// AC-02a (Codex parity audit P11): the 예약 활성화 controls against a fake
/// scheduler — ON asks first and cancel saves nothing, ON needs a CLI, OFF
/// works while the schedule is unusable, a failed save shows the real state.
@MainActor
enum ActivationSettingsTests {
    static func run() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let fake = FakeScheduler()
        let model = ActivationSettingsModel(load: { fake.view }, save: { fake.save($0) })
        model.refresh()

        model.requestSwitch(on: true)
        if !model.confirming || fake.saves != 0 { failures.append("ON saved before confirming") }
        model.cancelEnable()
        if model.confirming || fake.saves != 0 || model.isOn { failures.append("cancel saved or stayed open") }

        model.requestSwitch(on: true)
        model.confirmEnable()
        if !model.isOn || fake.saves != 1 || !fake.view.config.enabled { failures.append("confirm did not turn on") }

        fake.view.config.claude = false
        fake.view.config.codex = false
        fake.view.config.enabled = false
        model.refresh()
        model.requestSwitch(on: true)
        if model.confirming || model.message == nil { failures.append("ON without a CLI was offered") }

        fake.view = ActivationScheduler.View(config: ActivationConfig(enabled: true, claude: true, codex: false),
                                             available: false, error: "다른 앱이 예약을 맡고 있음")
        model.refresh()
        if !model.canSwitch || model.canPickProviders { failures.append("OFF not reachable while unusable") }
        model.requestSwitch(on: false)
        if model.isOn || fake.view.config.enabled { failures.append("OFF did not apply while unusable") }
        model.requestSwitch(on: true)
        if model.confirming { failures.append("ON offered while unusable") }

        fake.view = ActivationScheduler.View(config: ActivationConfig(enabled: true, claude: true, codex: false), available: true)
        model.refresh()
        fake.failNextSave = true
        model.requestSwitch(on: false)
        if model.isOn || model.message == nil { failures.append("failed save did not re-read the real state") }

        fake.view.history = [ActivationRun(provider: .claude, slot: "2026-11-08T06:00:00+09:00", status: "success", detail: "ok")]
        model.refresh()
        if model.view.history.count != 1 { failures.append("refresh missed new history") }

        return .make("AC-02a", "예약 켜기 전 확인(취소 시 저장 없음)·CLI 필요·사용 불가여도 OFF·저장 실패 시 실제 상태",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    /// Mirrors the real save: OFF takes effect in memory even when the file
    /// write fails; ON needs a CLI and a usable schedule.
    @MainActor
    private final class FakeScheduler {
        var view = ActivationScheduler.View(config: ActivationConfig(enabled: false, claude: true, codex: false), available: true)
        var saves = 0
        var failNextSave = false

        func save(_ config: ActivationConfig) -> Result<ActivationScheduler.View, ActivationFailure> {
            saves += 1
            if !config.enabled { view.config = config }
            if failNextSave {
                failNextSave = false
                return .failure("예약 파일을 저장하지 못했습니다")
            }
            guard !config.enabled || config.claude || config.codex else { return .failure("CLI를 하나 이상 고르세요") }
            guard view.available || !config.enabled else { return .failure("예약을 쓸 수 없습니다") }
            view.config = config
            return .success(view)
        }
    }
}
