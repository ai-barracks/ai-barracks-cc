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
        let base = TerminalConfiguration.default
            .fontSize(AppConstants.Terminal.fontSize)
            .minimumContrast(AppConstants.Terminal.minimumContrast)
            .windowPaddingX(AppConstants.Terminal.paddingX)
            .windowPaddingY(AppConstants.Terminal.paddingY)
        // Unbind Ghostty defaults that collide with app menu shortcuts so the
        // menu, not the terminal, receives them.
        let configuration = AppConstants.Terminal.appReservedChords.reduce(base) { config, chord in
            config.custom("keybind", "\(chord)=unbind")
        }
        return TerminalController(configuration: configuration)
    }
}
