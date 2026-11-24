import AppKit
import Carbon.HIToolbox

/// Builds in-process NSEvents and posts them to the app's event queue, so they
/// are dequeued by the run loop like real input: `NSApp.currentEvent` is set,
/// key equivalents and menus run, and mouse events are hit-tested. Callers
/// must yield (await) for queued events to be processed.
@MainActor
enum EventSynthesizer {
    struct Key: Sendable {
        let keyCode: UInt16
        let characters: String
        let unmodified: String
        let modifiers: NSEvent.ModifierFlags
    }

    private static var eventNumber = 0

    // MARK: - Keys

    static func key(_ character: Character, modifiers: NSEvent.ModifierFlags = []) -> Key? {
        let lower = Character(character.lowercased())
        guard let code = asciiKeyCodes[lower] else { return nil }
        let isUpper = character.isUppercase
        let flags = isUpper ? modifiers.union(.shift) : modifiers
        let text = String(character)
        return Key(keyCode: code, characters: text, unmodified: String(lower), modifiers: flags)
    }

    static let space = Key(keyCode: UInt16(kVK_Space), characters: " ", unmodified: " ", modifiers: [])
    static let returnKey = Key(keyCode: UInt16(kVK_Return), characters: "\r", unmodified: "\r", modifiers: [])
    static let downArrow: Key = {
        let arrow = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        return Key(keyCode: UInt16(kVK_DownArrow), characters: arrow, unmodified: arrow, modifiers: [.function, .numericPad])
    }()
    static let escape = Key(keyCode: UInt16(kVK_Escape), characters: "\u{1b}", unmodified: "\u{1b}", modifiers: [])
    static let delete = Key(keyCode: UInt16(kVK_Delete), characters: "\u{7f}", unmodified: "\u{7f}", modifiers: [])

    static let commandEqual = Key(keyCode: UInt16(kVK_ANSI_Equal), characters: "=", unmodified: "=", modifiers: .command)
    static let commandMinus = Key(keyCode: UInt16(kVK_ANSI_Minus), characters: "-", unmodified: "-", modifiers: .command)

    static func command(_ letter: Character, extra: NSEvent.ModifierFlags = []) -> Key? {
        guard let code = asciiKeyCodes[letter] else { return nil }
        return Key(keyCode: code, characters: String(letter), unmodified: String(letter), modifiers: extra.union(.command))
    }

    static func control(_ letter: Character) -> Key? {
        guard let code = asciiKeyCodes[letter], let ascii = letter.asciiValue else { return nil }
        let controlChar = String(UnicodeScalar(ascii & 0x1f))
        return Key(keyCode: code, characters: controlChar, unmodified: String(letter), modifiers: .control)
    }

    static func press(_ key: Key, in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: key.modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: key.characters,
                charactersIgnoringModifiers: key.unmodified,
                isARepeat: false,
                keyCode: key.keyCode
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Types ASCII text; returns false if a character has no key mapping.
    @discardableResult
    static func type(_ text: String, in window: NSWindow) -> Bool {
        for character in text {
            let key = character == " " ? space : key(character)
            guard let key else { return false }
            press(key, in: window)
        }
        return true
    }

    // MARK: - Mouse

    static func mouse(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        in window: NSWindow,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        eventNumber += 1
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    static func click(at point: NSPoint, count: Int, in window: NSWindow) {
        for _ in 0..<max(count, 1) {
            mouse(.leftMouseDown, at: point, in: window)
            mouse(.leftMouseUp, at: point, in: window)
        }
    }

    static func drag(
        from start: NSPoint,
        to end: NSPoint,
        steps: Int,
        in window: NSWindow,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        mouse(.leftMouseDown, at: start, in: window, modifiers: modifiers)
        let count = max(steps, 1)
        for step in 1...count {
            let fraction = CGFloat(step) / CGFloat(count)
            let point = NSPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction
            )
            mouse(.leftMouseDragged, at: point, in: window, modifiers: modifiers)
        }
        mouse(.leftMouseUp, at: end, in: window, modifiers: modifiers)
    }

    // MARK: - Tables

    private static let asciiKeyCodes: [Character: UInt16] = [
        "a": UInt16(kVK_ANSI_A), "b": UInt16(kVK_ANSI_B), "c": UInt16(kVK_ANSI_C),
        "d": UInt16(kVK_ANSI_D), "e": UInt16(kVK_ANSI_E), "f": UInt16(kVK_ANSI_F),
        "g": UInt16(kVK_ANSI_G), "h": UInt16(kVK_ANSI_H), "i": UInt16(kVK_ANSI_I),
        "j": UInt16(kVK_ANSI_J), "k": UInt16(kVK_ANSI_K), "l": UInt16(kVK_ANSI_L),
        "m": UInt16(kVK_ANSI_M), "n": UInt16(kVK_ANSI_N), "o": UInt16(kVK_ANSI_O),
        "p": UInt16(kVK_ANSI_P), "q": UInt16(kVK_ANSI_Q), "r": UInt16(kVK_ANSI_R),
        "s": UInt16(kVK_ANSI_S), "t": UInt16(kVK_ANSI_T), "u": UInt16(kVK_ANSI_U),
        "v": UInt16(kVK_ANSI_V), "w": UInt16(kVK_ANSI_W), "x": UInt16(kVK_ANSI_X),
        "y": UInt16(kVK_ANSI_Y), "z": UInt16(kVK_ANSI_Z),
        "0": UInt16(kVK_ANSI_0), "1": UInt16(kVK_ANSI_1), "2": UInt16(kVK_ANSI_2),
        "3": UInt16(kVK_ANSI_3), "4": UInt16(kVK_ANSI_4), "5": UInt16(kVK_ANSI_5),
        "6": UInt16(kVK_ANSI_6), "7": UInt16(kVK_ANSI_7), "8": UInt16(kVK_ANSI_8),
        "9": UInt16(kVK_ANSI_9),
    ]
}
