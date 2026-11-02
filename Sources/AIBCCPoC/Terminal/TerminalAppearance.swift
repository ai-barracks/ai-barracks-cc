import GhosttyTerminal

/// Shared Ghostty controller: one config for every pane so readability
/// settings (RD-01..03) stay consistent. No font-family override: "SF Mono"
/// is not addressable by name outside Apple's own apps, and naming a Korean
/// font first made Ghostty use its wide ASCII metrics (first-launch capture,
/// 2026-10-31). Ghostty's bundled default plus CoreText fallback for Hangul
/// keeps cell widths correct.
@MainActor
enum TerminalAppearance {
    static func makeController() -> TerminalController {
        TerminalController(configuration: configuration(AppSettings.terminal()))
    }

    /// The user's terminal settings over the readability baseline; the
    /// font family is only set when the user chose one.
    static func configuration(_ settings: AppSettings.Terminal) -> TerminalConfiguration {
        var base = TerminalConfiguration.default
            .fontSize(Float(settings.fontSize))
            .minimumContrast(AppConstants.Terminal.minimumContrast)
            .windowPaddingX(AppConstants.Terminal.paddingX)
            .windowPaddingY(AppConstants.Terminal.paddingY)
            .cursorStyle(settings.cursor)
        if !settings.fontFamily.isEmpty { base = base.fontFamily(settings.fontFamily) }
        // Unbind Ghostty defaults that collide with app menu shortcuts so the
        // menu, not the terminal, receives them.
        return AppConstants.Terminal.appReservedChords.reduce(base) { config, chord in
            config.custom("keybind", "\(chord)=unbind")
        }
    }
}
