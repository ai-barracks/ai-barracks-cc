import AppKit
import SwiftUI

/// Under the sidebar's version line: the release on offer, or progress.
struct UpdateBadge: View {
    private let updater = AppUpdater.shared

    var body: some View {
        if updater.state == .installing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("업데이트 설치 중…").font(Tokens.Font.meta).foregroundStyle(Tokens.textSecondary)
            }
        } else if let release = updater.available {
            VStack(alignment: .leading, spacing: 2) {
                Button { updater.confirming = release } label: {
                    Label("v\(release.version) 업데이트", systemImage: "arrow.down.circle.fill").font(Tokens.Font.meta)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .help("새 버전으로 바꾸고 다시 시작합니다. 열린 에이전트·터미널은 계속 실행됩니다.")
                if let error = updater.installError {
                    Text(error).font(Tokens.Font.meta).foregroundStyle(Tokens.red).lineLimit(3)
                }
            }
        }
    }
}

/// "v2.2.0으로 업데이트할까요?" — the only way an update is installed.
struct UpdatePrompt: ViewModifier {
    private let updater = AppUpdater.shared

    func body(content: Content) -> some View {
        content.alert(updater.confirming.map { "v\($0.version)으로 업데이트할까요?" } ?? "",
                      isPresented: Binding(get: { updater.confirming != nil },
                                           set: { if !$0 { updater.confirming = nil } })) {
            if let release = updater.confirming {
                Button("업데이트 후 다시 시작") { Task { await updater.install(release) } }
                Button("릴리스 노트 보기") { NSWorkspace.shared.open(release.page) }
                Button("나중에", role: .cancel) {}
            }
        } message: {
            Text("지금 \(updater.current.map { "v\($0)" } ?? AppVersion.label). GitHub 릴리스를 내려받아 SHA-256과 서명을 확인한 뒤 앱을 바꾸고 다시 시작합니다. "
                 + AppUpdater.sessionsNote + " 이전 버전은 한 개 백업해 둡니다.")
        }
    }
}

/// Settings › 업데이트.
struct UpdateSettingsSection: View {
    @State private var autoCheck = AppUpdater.shared.autoCheck
    private let updater = AppUpdater.shared

    var body: some View {
        Section {
            Toggle("시작할 때와 하루 한 번 확인", isOn: $autoCheck)
                .onChange(of: autoCheck) { updater.autoCheck = autoCheck }
                .disabled(updater.current == nil)
            HStack {
                Text(status).foregroundStyle(Tokens.textSecondary)
                Spacer()
                Button("지금 확인") { Task { await updater.check(userInitiated: true) } }
                    .disabled(updater.state == .checking || updater.state == .installing)
            }
        } header: {
            Text("업데이트")
        } footer: {
            Text("GitHub의 최신 릴리스만 봅니다(요청에 개인 정보 없음). 설치는 묻고 나서만 합니다.")
                .font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
        }
    }

    private var status: String {
        switch updater.state {
        case .idle: updater.current == nil ? "개발 빌드 — 확인하지 않음" : "아직 확인 안 함"
        case .checking: "확인 중…"
        case .upToDate: "최신 버전입니다" + (updater.lastChecked.map { " · \($0.formatted(date: .omitted, time: .shortened)) 확인" } ?? "")
        case .installing: "설치 중…"
        case let .available(release): "v\(release.version) 있음"
        case let .failed(why): why
        }
    }
}

extension WorkspaceModel {
    /// App menu › 업데이트 확인…: always answers.
    func checkForUpdates() async {
        let updater = AppUpdater.shared
        await updater.check(userInitiated: true)
        let current = updater.current.map { "v\($0)" } ?? AppVersion.label
        switch updater.state {
        case .upToDate: notices.post(AppNotice(kind: .update, title: "최신 버전입니다", body: "CommandCenter \(current)",
                                               actionLabel: nil, barrackID: nil, sessionID: nil))
        case let .failed(why): notices.post(AppNotice(kind: .update, title: "업데이트 확인 실패", body: why,
                                                      actionLabel: nil, barrackID: nil, sessionID: nil))
        default: break
        }
    }
}
