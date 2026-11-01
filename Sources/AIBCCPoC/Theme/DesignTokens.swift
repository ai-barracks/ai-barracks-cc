import AppKit
import SwiftUI

/// v2 design tokens (resources/design/aibcc-v2-design-spec, §2): semantic
/// colors that keep their role in Dark (primary) and Light.
enum Tokens {
    static let work = Color(dark: 0x15171A, light: 0xFFFFFF)
    static let panel = Color(dark: 0x1B1E22, light: 0xF6F7F8)
    static let raised = Color(dark: 0x23272C, light: 0xFFFFFF)
    static let line = Color(dark: 0x2D3238, light: 0xE3E6E9)
    static let textPrimary = Color(dark: 0xE7E9EC, light: 0x1A1D21)
    static let textSecondary = Color(dark: 0xA1A8B0, light: 0x5B636C)
    static let textTertiary = Color(dark: 0x6B737C, light: 0x8C939B)
    static let teal = Color(dark: 0x2EB5A5, light: 0x10877A)
    static let orange = Color(dark: 0xF29A4A, light: 0xC2650F)
    static let red = Color(dark: 0xEB5A5A, light: 0xC23A3A)
    static let green = Color(dark: 0x5CC48A, light: 0x23874F)
    static let idle = Color(dark: 0x5A6169, light: 0xAAB1B8)

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
    }

    enum Radius {
        static let row: CGFloat = 6
        static let card: CGFloat = 10
    }

    enum Motion {
        static let transition = Animation.easeOut(duration: 0.16)
    }

    enum Font {
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyMedium = SwiftUI.Font.system(size: 13, weight: .medium)
        static let meta = SwiftUI.Font.system(size: 11)
        static let title = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let numeric = SwiftUI.Font.system(size: 11).monospacedDigit()
    }
}

extension Color {
    /// A color that follows the effective appearance (Dark / Light).
    init(dark: UInt32, light: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
