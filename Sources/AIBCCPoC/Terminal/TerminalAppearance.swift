import GhosttyTerminal

/// Shared Ghostty controller: one config for every pane so readability
/// settings (RD-01..03) stay consistent.
@MainActor
enum TerminalAppearance {
    static func makeController() -> TerminalController {
        let configuration = TerminalConfiguration.default
            .fontFamily(AppConstants.Terminal.fontFamily)
            .fontFamily(AppConstants.Terminal.fallbackFontFamily)
            .fontSize(AppConstants.Terminal.fontSize)
            .minimumContrast(AppConstants.Terminal.minimumContrast)
            .windowPaddingX(AppConstants.Terminal.paddingX)
            .windowPaddingY(AppConstants.Terminal.paddingY)
        return TerminalController(configuration: configuration)
    }
}
