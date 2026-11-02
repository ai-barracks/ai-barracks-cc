import AppKit
import GhosttyTerminal
import SwiftUI

/// User settings (v1 TerminalSettings + System info parity). Self-tests
/// always run on the defaults so a user's choice cannot skew a result.
enum AppSettings {
    static let fontSizeKey = "terminalFontSize"
    static let cursorKey = "terminalCursorStyle"
    static let fontFamilyKey = "terminalFontFamily"
    static let appearanceKey = "appearance"
    static let fontSizeRange: ClosedRange<Double> = 10...24

    struct Terminal: Equatable {
        var fontSize = Double(AppConstants.Terminal.fontSize)
        var cursor = TerminalCursorStyle.block
        var fontFamily = ""
    }

    static var isSelfTest: Bool { CommandLine.arguments.contains { $0.hasPrefix("--selftest") } }

    static func terminal(_ defaults: UserDefaults = .standard) -> Terminal {
        guard !isSelfTest else { return Terminal() }
        let size = defaults.object(forKey: fontSizeKey) as? Double ?? Double(AppConstants.Terminal.fontSize)
        return Terminal(fontSize: min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound),
                        cursor: TerminalCursorStyle(rawValue: defaults.string(forKey: cursorKey) ?? "") ?? .block,
                        fontFamily: defaults.string(forKey: fontFamilyKey) ?? "")
    }

    /// "system" follows macOS; "light"/"dark" force the window appearance.
    @MainActor
    static func applyAppearance(_ defaults: UserDefaults = .standard) {
        switch defaults.string(forKey: appearanceKey) {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    static var monospacedFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            NSFont(name: family, size: 13).map { $0.isFixedPitch } ?? false
        }
    }
}

struct SettingsView: View {
    let workspace: WorkspaceModel
    @AppStorage(AppSettings.fontSizeKey) private var fontSize = Double(AppConstants.Terminal.fontSize)
    @AppStorage(AppSettings.cursorKey) private var cursor = TerminalCursorStyle.block.rawValue
    @AppStorage(AppSettings.fontFamilyKey) private var fontFamily = ""
    @AppStorage(AppSettings.appearanceKey) private var appearance = "system"
    @AppStorage(AppConstants.Daemon.keepSessionsOnQuitKey) private var keepSessions = true
    @State private var aibVersion = "확인 중…"

    var body: some View {
        Form {
            Section("터미널") {
                Stepper("글꼴 크기 \(Int(fontSize))pt", value: $fontSize, in: AppSettings.fontSizeRange)
                Picker("커서", selection: $cursor) {
                    Text("블록").tag("block"); Text("막대").tag("bar"); Text("밑줄").tag("underline")
                }
                Picker("글꼴", selection: $fontFamily) {
                    Text("기본 (권장)").tag("")
                    ForEach(AppSettings.monospacedFamilies, id: \.self) { Text($0).tag($0) }
                }
                Text("한글 글꼴을 고정폭 글꼴 대신 지정하면 영문 칸 폭이 넓어질 수 있습니다.")
                    .font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
            }
            Section("화면") {
                Picker("모드", selection: $appearance) {
                    Text("시스템").tag("system"); Text("라이트").tag("light"); Text("다크").tag("dark")
                }
            }
            Section("세션") {
                Toggle("앱 종료 시 세션 유지", isOn: $keepSessions).disabled(workspace.daemon == nil)
            }
            ActivationSettingsSection(scheduler: workspace.activation)
            Section {
                ForEach(ProviderProfiles.clients) { ProviderProfileRow(client: $0) }
            } header: {
                Text("모델 프로필 (새 세션)")
            } footer: {
                Text("⌘N으로 여는 새 세션에만 적용(aib start --model/--effort). 목록 조회는 모델 요청을 보내지 않습니다 — Codex는 설치된 CLI·계정이 알리는 목록, Claude는 문서상 alias이며 실제 지원 여부는 CLI가 확인합니다.")
                    .font(Tokens.Font.meta).foregroundStyle(Tokens.textTertiary)
            }
            Section("정보") {
                LabeledContent("AIBCC", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                LabeledContent("aib CLI", value: aibVersion)
                LabeledContent("PTY", value: workspace.daemon == nil ? "앱 소유(exec)" : "데몬(세션 유지)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onChange(of: fontSize) { workspace.applySettings() }
        .onChange(of: cursor) { workspace.applySettings() }
        .onChange(of: fontFamily) { workspace.applySettings() }
        .onChange(of: appearance) { AppSettings.applyAppearance() }
        .task {
            let path = workspace.selectedBarrack?.path ?? NSHomeDirectory()
            let output = await AibShell.run("aib version", in: path).trimmingCharacters(in: .whitespacesAndNewlines)
            aibVersion = output.isEmpty ? "찾을 수 없음 (PATH)" : output
        }
    }
}
