import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A shortcut by key position (virtual key code) and modifiers, so it works
/// whatever the input source: under Korean 2-Set the W key reads ㅉ, and the
/// menu did not match ⌘⇧ with a letter for layout-shaped events
/// (known-issues #18). Names are the ANSI keyboard's.
struct KeyChord: Codable, Hashable, Sendable {
    struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1)
        static let shift = Modifiers(rawValue: 2)
        static let option = Modifiers(rawValue: 4)
        static let control = Modifiers(rawValue: 8)
    }

    let keyCode: UInt16
    let modifiers: Modifiers

    init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(_ keyCode: Int, _ modifiers: Modifiers) {
        self.init(keyCode: UInt16(keyCode), modifiers: modifiers)
    }

    /// From an event: Caps Lock, fn and the keypad flag do not count.
    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        let pairs: [(NSEvent.ModifierFlags, Modifiers)] = [
            (.command, .command), (.shift, .shift), (.option, .option), (.control, .control),
        ]
        self.init(keyCode: keyCode, modifiers: Modifiers(pairs.filter { flags.contains($0.0) }.map(\.1)))
    }

    var key: KeyNames.Key? { KeyNames.key(keyCode) }

    /// "⌃⌥⇧⌘K", the order macOS menus use.
    var display: String {
        let marks: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return marks.filter { modifiers.contains($0.0) }.map(\.1).joined() + (key?.name ?? "#\(keyCode)")
    }

    /// For menus, which show it; the event monitor does the work.
    var keyboardShortcut: KeyboardShortcut? {
        guard let key else { return nil }
        let pairs: [(Modifiers, SwiftUI.EventModifiers)] = [
            (.command, .command), (.shift, .shift), (.option, .option), (.control, .control),
        ]
        return KeyboardShortcut(key.equivalent, modifiers: SwiftUI.EventModifiers(pairs.filter { modifiers.contains($0.0) }.map(\.1)))
    }

    /// Stored as "keyCode:modifiers".
    var stored: String { "\(keyCode):\(modifiers.rawValue)" }

    init?(stored: String) {
        let parts = stored.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let code = UInt16(exactly: parts[0]) else { return nil }
        self.init(keyCode: code, modifiers: Modifiers(rawValue: parts[1]))
    }
}

/// ANSI key positions a shortcut may use: letters, digits, punctuation,
/// arrows and a few named keys. Escape is not one (it cancels recording).
enum KeyNames {
    struct Key: Sendable {
        let name: String
        let equivalent: KeyEquivalent
    }

    static func key(_ code: UInt16) -> Key? { table[Int(code)] }

    private static let table: [Int: Key] = {
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"),
            (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_RightBracket, "]"),
            (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."),
            (kVK_ANSI_Slash, "/"), (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Grave, "`"),
        ]
        let plain = letters.map { code, name in
            (code, Key(name: name, equivalent: KeyEquivalent(Character(name.lowercased()))))
        }
        let named: [(Int, Key)] = [
            (kVK_UpArrow, Key(name: "↑", equivalent: .upArrow)), (kVK_DownArrow, Key(name: "↓", equivalent: .downArrow)),
            (kVK_LeftArrow, Key(name: "←", equivalent: .leftArrow)), (kVK_RightArrow, Key(name: "→", equivalent: .rightArrow)),
            (kVK_Return, Key(name: "↩", equivalent: .return)), (kVK_Tab, Key(name: "⇥", equivalent: .tab)),
            (kVK_Space, Key(name: "Space", equivalent: .space)), (kVK_Delete, Key(name: "⌫", equivalent: .delete)),
        ]
        return Dictionary(plain + named) { first, _ in first }
    }()
}
