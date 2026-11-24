import AppKit
import Carbon.HIToolbox

/// ⌘⇧W ("정리하고 닫기") by key position, whatever the input source. The
/// menu item alone was not reached: AppKit's menu did not match ⌘⇧ with a
/// letter for events carrying the layout's characters ("W", and "ㅉ" under
/// the Korean source), and the key fell through to the terminal as a no-op
/// (WU-01c, 2026-11-24). The menu item stays to show the shortcut; this
/// runs before it and takes the key in the window that holds the terminals.
@MainActor
enum WrapUpShortcut {
    private static var monitor: Any?

    static func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let modifiers = flags.intersection([.command, .shift, .option, .control])
        return keyCode == UInt16(kVK_ANSI_W) && modifiers == [.command, .shift]
    }

    static func install(workspace: WorkspaceModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak workspace] event in
            let keyCode = event.keyCode, flags = event.modifierFlags, windowNumber = event.windowNumber
            let taken = MainActor.assumeIsolated { () -> Bool in
                guard matches(keyCode: keyCode, flags: flags), let workspace,
                      let window = NSApp.window(withWindowNumber: windowNumber), window.attachedSheet == nil,
                      workspace.panes.contains(where: { $0.probeView?.window === window })
                else { return false }
                workspace.toggleWrapUp(of: workspace.wrapUpTarget)
                return true
            }
            return taken ? nil : event
        }
    }
}
