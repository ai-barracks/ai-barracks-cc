import AppKit
import SwiftUI

/// "CommandCenter v…" and the aib CLI version at the top of the sidebar,
/// as v1 showed them (2026-11-23 feedback).
struct AppVersionHeader: View {
    let workspace: WorkspaceModel
    @State private var cliVersion = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text("CommandCenter").font(Tokens.Font.bodyMedium).foregroundStyle(Tokens.textPrimary)
                Text(AppVersion.label).font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Text(cliVersion.isEmpty ? "AI Barracks" : "AI Barracks v\(cliVersion)")
                .font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary).lineLimit(1)
        }
        .padding(.horizontal, Tokens.Spacing.s)
        .help(AppVersion.details)
        // `aib version`, once, from the user's login shell (read only).
        .task {
            let output = await AibShell.run("aib version", in: NSHomeDirectory())
            cliVersion = AppVersion.cliVersion(in: output) ?? ""
        }
    }
}

/// What the running app says about itself.
enum AppVersion {
    private static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    /// "v2.0.0-beta.10" for a release, "dev" for a development build.
    static var label: String { label(from: info) }

    static func label(from info: [String: Any]) -> String {
        if let label = info["AIBVersionLabel"] as? String, !label.isEmpty {
            return label == "dev" ? "dev" : "v" + label
        }
        return "v" + ((info["CFBundleShortVersionString"] as? String) ?? "?")
    }

    /// "1.6.0" from `aib version`'s output.
    static func cliVersion(in output: String) -> String? {
        output.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression).map { String(output[$0]) }
    }

    static var details: String {
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = (info["AIBSourceCommit"] as? String).map { String($0.prefix(7)) } ?? "?"
        return "CommandCenter \(label) · build \(build) · \(commit)"
    }
}

/// "주의 N · 작업 중 M": whether anything needs the user. Clicking it lists
/// what is counted and goes there (2026-11-23 feedback: the numbers said
/// nothing about what they counted or where to look).
struct AttentionSummary: View {
    let workspace: WorkspaceModel
    @State private var isShowing = false

    var body: some View {
        let attention = workspace.liveness.attentionCount
        let working = workspace.liveness.workingCount
        Button { isShowing.toggle() } label: {
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: attention > 0 ? "exclamationmark.circle.fill" : "checkmark.circle")
                    .foregroundStyle(attention > 0 ? Tokens.orange : Tokens.textTertiary)
                Text(attention > 0 ? "주의 \(attention)" : "주의 없음")
                    .fontWeight(attention > 0 ? .semibold : .regular)
                    .foregroundStyle(attention > 0 ? Tokens.orange : Tokens.textSecondary)
                Text("· 작업 중 \(working)").foregroundStyle(Tokens.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Tokens.textTertiary)
            }
            .font(Tokens.Font.body)
            .padding(.horizontal, Tokens.Spacing.s)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.card)
                    .fill(attention > 0 ? Tokens.orange.opacity(0.12) : Color.primary.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("주의: 입력을 기다리거나 끝났는데 아직 안 본 에이전트 세션 · 작업 중: 지금 응답을 만들고 있는 세션 — 눌러서 목록 보기")
        .popover(isPresented: $isShowing, arrowEdge: .trailing) {
            AttentionPopover(workspace: workspace) { isShowing = false }
        }
    }
}

/// The sessions behind the two numbers, each a click away.
struct AttentionPopover: View {
    let workspace: WorkspaceModel
    let close: () -> Void

    var body: some View {
        let attention = workspace.attentionItems
        let working = workspace.workingItems
        let silent = workspace.silentItems
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            section("주의 \(attention.count)", empty: "확인할 세션이 없습니다.", items: attention)
            if attention.contains(where: { $0.session.state == .done }) {
                Button("완료한 세션 모두 확인함으로") { workspace.acknowledgeFinished() }
                    .controlSize(.small)
                    .help("끝났다는 표시만 지웁니다. 세션과 터미널은 그대로입니다.")
            }
            Divider()
            section("작업 중 \(working.count)", empty: "지금 응답을 만들고 있는 세션이 없습니다.", items: working)
            if !silent.isEmpty {
                section("응답 없음 \(silent.count)", empty: "", items: silent)
            }
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text("주의 — 입력 대기(에이전트가 답을 기다림), 비정상 종료, 완료(끝났는데 아직 안 봄, 12시간 이내)")
                Text("작업 중 — 지금 응답을 만들고 있는 세션. 입력을 기다리는 동안은 세지 않습니다")
                Text("응답 없음 — 작업 중이라고 한 뒤 3분 넘게 소식이 없는 세션(세지 않음). 오래됐다면 터미널을 확인하세요")
                Text("aib start로 시작한 Claude·Codex·Gemini 세션만 셉니다. 누르면 그 터미널로 갑니다(⌘⇧A: 다음 주의)")
            }
            .font(Tokens.Font.meta)
            .foregroundStyle(Tokens.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Spacing.m)
        .frame(width: 340)
    }

    @ViewBuilder
    private func section(_ title: String, empty: String, items: [(barrack: Barrack, session: LiveSession)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Tokens.Font.meta.weight(.semibold)).foregroundStyle(Tokens.textSecondary)
            if items.isEmpty {
                Text(empty).font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
            }
            ForEach(items, id: \.session.id) { item in
                Button {
                    close()
                    workspace.goTo(item.session, in: item.barrack)
                } label: {
                    SessionLine(barrack: item.barrack, session: item.session,
                                terminal: workspace.pane(running: item.session, in: item.barrack.id)?.title)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SessionLine: View {
    let barrack: Barrack
    let session: LiveSession
    let terminal: String?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            LivenessBeacon(state: session.state)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(barrack.name).font(Tokens.Font.bodyMedium).lineLimit(1)
                    Text(session.state.label).font(Tokens.Font.meta).foregroundStyle(session.state.tint)
                    Spacer(minLength: 4)
                    Text(Self.age(session.ageSeconds)).font(Tokens.Font.numeric).foregroundStyle(Tokens.textTertiary)
                }
                Text(terminal.map { "터미널: \($0)" } ?? "이 앱의 터미널에서 돌지 않음 — 배럭 화면으로")
                    .font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.row).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("\(session.id) · pid \(session.pid)")
    }

    static func age(_ seconds: Int) -> String {
        seconds < 60 ? "방금" : seconds < 3600 ? "\(seconds / 60)분 전" : seconds < 86_400 ? "\(seconds / 3600)시간 전" : "\(seconds / 86_400)일 전"
    }
}
