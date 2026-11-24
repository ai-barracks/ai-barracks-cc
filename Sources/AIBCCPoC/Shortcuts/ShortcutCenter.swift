import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Runs the user's shortcuts by key position, before menus and the
/// terminal (Ghostty's own ⌘-bindings never see them). Only in the main
/// window with nothing on top of it; elsewhere keys go on as usual. While
/// Settings records a shortcut, the next key goes to the recorder instead.
@MainActor
enum ShortcutCenter {
    private static var monitor: Any?
    /// Settings → 단축키 is waiting for a key: the chord, or nil for Esc.
    static var recorder: ((KeyChord?) -> Void)?

    static func install(workspace: WorkspaceModel, store: ShortcutStore = .shared) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak workspace] event in
            let keyCode = event.keyCode, flags = event.modifierFlags
            let windowNumber = event.windowNumber, isRepeat = event.isARepeat
            let taken = MainActor.assumeIsolated { () -> Bool in
                guard let workspace else { return false }
                return handle(KeyChord(keyCode: keyCode, flags: flags), windowNumber: windowNumber,
                              isRepeat: isRepeat, workspace: workspace, store: store)
            }
            return taken ? nil : event
        }
    }

    /// true: the key is used up.
    static func handle(_ chord: KeyChord, windowNumber: Int, isRepeat: Bool,
                       workspace: WorkspaceModel, store: ShortcutStore) -> Bool {
        if let record = recorder {
            guard !isRepeat else { return true }
            recorder = nil
            record(chord.keyCode == UInt16(kVK_Escape) && chord.modifiers.isEmpty ? nil : chord)
            return true
        }
        guard let action = store.action(for: chord), let window = NSApp.window(withWindowNumber: windowNumber),
              isMainWindow(window)
        else { return false }
        // Held down: once, not a flicker of toggles (the key is still used up).
        if !isRepeat || action.repeats { workspace.perform(action) }
        return true
    }

    /// The terminals' window, with no sheet or dialog over it.
    static func isMainWindow(_ window: NSWindow) -> Bool {
        window.attachedSheet == nil && !(window is NSPanel) && window.isVisible
            && !(window.identifier?.rawValue ?? "").contains("Settings")
    }
}

extension ShortcutAction {
    /// Moving between panes or barracks repeats while held; the rest once.
    var repeats: Bool { [.focusNextPane, .focusPreviousPane, .nextBarrack, .previousBarrack].contains(self) }
}

/// A menu item for a shortcut action, showing its current key. A key that
/// reaches it is checked against the store: the menu can still hold the
/// key it had before a change (KB-01b: ⌘K opened the palette after it
/// moved to ⌘⇧P). Clicks always run.
struct ShortcutMenuItem: View {
    let action: ShortcutAction
    let workspace: WorkspaceModel
    var title: String?
    private let store = ShortcutStore.shared

    var body: some View {
        Button(title ?? action.title) {
            if let event = NSApp.currentEvent, event.type == .keyDown,
               KeyChord(keyCode: event.keyCode, flags: event.modifierFlags) != store.chord(for: action) {
                return
            }
            workspace.perform(action)
        }
        .keyboardShortcut(store.chord(for: action)?.keyboardShortcut)
    }
}
