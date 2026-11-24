import AppKit
import ApplicationServices

/// Finds, launches and arranges another app's window through the
/// Accessibility API (the reason this helper needs that permission).
enum Targets {
    static func running(_ bundle: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
    }

    static func launch(_ bundle: String) async -> NSRunningApplication? {
        if let app = running(bundle) { return app }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Brings the app forward with AX (a background helper cannot rely on
    /// NSRunningApplication.activate under cooperative activation).
    static func bringToFront(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window = mainWindow(pid) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    static func mainWindow(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success, let value {
                return (value as! AXUIElement)
            }
        }
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return nil }
        return list.first
    }

    /// Global top-left coordinates, as AX and CGEvent use them.
    static func frame(of window: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func setFrame(_ window: AXUIElement, _ rect: CGRect) {
        var origin = rect.origin
        var size = rect.size
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    /// CGWindowID of the app's on-screen window whose bounds match `frame`
    /// (bounds and owner need no screen-recording permission).
    static func windowNumber(pid: pid_t, frame: CGRect) -> Int? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let candidates = list.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        func distance(_ info: [String: Any]) -> CGFloat {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return .infinity }
            return abs((bounds["X"] ?? 0) - frame.minX) + abs((bounds["Y"] ?? 0) - frame.minY)
                + abs((bounds["Width"] ?? 0) - frame.width) + abs((bounds["Height"] ?? 0) - frame.height)
        }
        return candidates.min { distance($0) < distance($1) }?[kCGWindowNumber as String] as? Int
    }
}
