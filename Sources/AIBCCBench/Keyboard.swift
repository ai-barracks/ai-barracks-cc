import CoreGraphics
import Foundation

/// US ANSI virtual key codes for the ASCII the scenarios type (the input
/// source is ABC during runs). Shifted characters reuse their base key.
enum Keyboard {
    struct Stroke {
        let code: CGKeyCode
        let flags: CGEventFlags
    }

    private static let base: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, " ": 49, "`": 50,
    ]
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
        "~": "`",
    ]
    static let named: [String: Stroke] = [
        "return": Stroke(code: 36, flags: []), "tab": Stroke(code: 48, flags: []),
        "escape": Stroke(code: 53, flags: []), "delete": Stroke(code: 51, flags: []),
        "ctrl-c": Stroke(code: 8, flags: .maskControl), "ctrl-d": Stroke(code: 2, flags: .maskControl),
        "ctrl-u": Stroke(code: 32, flags: .maskControl),
        "cmd-n": Stroke(code: 45, flags: .maskCommand),
        "cmd-k": Stroke(code: 40, flags: .maskCommand),
    ]

    static func stroke(for character: Character) -> Stroke? {
        if let code = base[character] { return Stroke(code: code, flags: []) }
        if character.isUppercase, let lower = character.lowercased().first, let code = base[lower] {
            return Stroke(code: code, flags: .maskShift)
        }
        if let plain = shifted[character], let code = base[plain] { return Stroke(code: code, flags: .maskShift) }
        return nil
    }

    /// Posts a key press to the HID tap: it goes to the frontmost app's key
    /// window like a real keyboard.
    static func press(_ stroke: Stroke) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.code, keyDown: down) else { continue }
            event.flags = stroke.flags
            event.post(tap: .cghidEventTap)
        }
    }

    static func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }
}
