import Carbon.HIToolbox
import Foundation
import Observation

/// The shortcut for each action: the default unless the user set one
/// (Settings → 단축키). Only changes are stored, so new defaults reach
/// people who never changed that action.
@MainActor
@Observable
final class ShortcutStore {
    enum Problem: Equatable {
        case needsCommand, unknownKey
        case reserved(String)
        case taken(ShortcutAction)

        var message: String {
            switch self {
            case .needsCommand: "⌘가 들어간 조합만 쓸 수 있습니다(터미널 입력과 겹치지 않게)."
            case .unknownKey: "이 키는 단축키로 쓸 수 없습니다."
            case let .reserved(use): "macOS·앱 기본 키입니다(\(use))."
            case let .taken(other): "이미 '\(other.title)'에 쓰고 있습니다."
            }
        }
    }

    static let shared = ShortcutStore()
    static let defaultsKey = "shortcuts.v1"

    /// Keys macOS or the app's editors already mean something by.
    static let reserved: [KeyChord: String] = [
        KeyChord(kVK_ANSI_Q, .command): "종료", KeyChord(kVK_ANSI_W, .command): "창 닫기",
        KeyChord(kVK_ANSI_W, [.command, .option]): "모두 닫기", KeyChord(kVK_ANSI_H, .command): "가리기",
        KeyChord(kVK_ANSI_H, [.command, .option]): "기타 가리기", KeyChord(kVK_ANSI_M, .command): "최소화",
        KeyChord(kVK_ANSI_Comma, .command): "설정", KeyChord(kVK_ANSI_C, .command): "복사",
        KeyChord(kVK_ANSI_V, .command): "붙여넣기", KeyChord(kVK_ANSI_X, .command): "잘라내기",
        KeyChord(kVK_ANSI_A, .command): "전체 선택", KeyChord(kVK_ANSI_Z, .command): "실행 취소",
        KeyChord(kVK_ANSI_Z, [.command, .shift]): "다시 실행", KeyChord(kVK_ANSI_S, .command): "문서 저장",
        KeyChord(kVK_ANSI_E, .command): "문서 편집", KeyChord(kVK_ANSI_Grave, .command): "창 전환",
        KeyChord(kVK_Tab, .command): "앱 전환", KeyChord(kVK_Space, .command): "Spotlight",
        KeyChord(kVK_ANSI_Equal, .command): "글꼴 크게", KeyChord(kVK_ANSI_Minus, .command): "글꼴 작게",
        KeyChord(kVK_ANSI_0, .command): "글꼴 원래대로", KeyChord(kVK_ANSI_F, [.command, .control]): "전체 화면",
        KeyChord(kVK_ANSI_L, [.command, .option, .shift]): "입력 호출 로그 저장",
    ]

    private let defaults: UserDefaults
    /// action id → stored chord, "" = no shortcut.
    private(set) var overrides: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        overrides = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    func chord(for action: ShortcutAction) -> KeyChord? {
        guard let stored = overrides[action.rawValue] else { return action.defaultChord }
        return KeyChord(stored: stored)
    }

    func isCustom(_ action: ShortcutAction) -> Bool { overrides[action.rawValue] != nil }

    func action(for chord: KeyChord) -> ShortcutAction? {
        ShortcutAction.allCases.first { self.chord(for: $0) == chord }
    }

    /// Saves it, or says why not (nothing changes then).
    @discardableResult
    func assign(_ chord: KeyChord, to action: ShortcutAction) -> Problem? {
        if let problem = problem(with: chord, for: action) { return problem }
        save(overrides.merging([action.rawValue: chord.stored]) { _, new in new })
        return nil
    }

    func problem(with chord: KeyChord, for action: ShortcutAction) -> Problem? {
        if chord.key == nil { return .unknownKey }
        if !chord.modifiers.contains(.command) { return .needsCommand }
        if let use = Self.reserved[chord] { return .reserved(use) }
        if let other = self.action(for: chord), other != action { return .taken(other) }
        return nil
    }

    func clear(_ action: ShortcutAction) {
        save(overrides.merging([action.rawValue: ""]) { _, new in new })
    }

    /// Back to the default — unless another action now holds that key.
    @discardableResult
    func reset(_ action: ShortcutAction) -> Problem? {
        let rest = overrides.filter { $0.key != action.rawValue }
        if let wanted = action.defaultChord,
           let other = ShortcutAction.allCases.first(where: { $0 != action && effective($0, in: rest) == wanted }) {
            return .taken(other)
        }
        save(rest)
        return nil
    }

    func resetAll() { save([:]) }

    /// Puts back a table read from `overrides` (self-test cleanup).
    func restore(_ table: [String: String]) { save(table) }

    private func effective(_ action: ShortcutAction, in table: [String: String]) -> KeyChord? {
        table[action.rawValue].map { KeyChord(stored: $0) } ?? action.defaultChord
    }

    private func save(_ table: [String: String]) {
        overrides = table
        defaults.set(table, forKey: Self.defaultsKey)
    }
}
