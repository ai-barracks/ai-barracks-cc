import Darwin
import Foundation

/// Runtime assets required by Ghostty's exec backend.
///
/// The package owns these assets and always points libghostty at this immutable
/// bundle location before the C runtime initializes. User-level Ghostty
/// resources and configuration are never consulted.
public enum GhosttyRuntimeResources {
    /// The package-bundled Ghostty resource directory.
    ///
    /// Ghostty expects shell integration below this directory and its compiled
    /// terminfo database in a sibling `terminfo` directory.
    public static var directoryURL: URL? {
        GhosttyResourceBundle.bundle.url(forResource: "Ghostty", withExtension: nil)
    }

    /// The compiled terminfo database exported to child shells by Ghostty.
    public static var terminfoDirectoryURL: URL? {
        GhosttyResourceBundle.bundle.url(forResource: "terminfo", withExtension: nil)
    }

    /// Where the resource bundle was found (AIBCC patch; lets the host verify
    /// it ships its own copy).
    public static var bundleURL: URL {
        GhosttyResourceBundle.bundle.bundleURL
    }

    static func configureEnvironment() {
        guard let path = directoryURL?.path else { return }
        setenv("GHOSTTY_RESOURCES_DIR", path, 1)
    }
}

/// AIBCC patch: SwiftPM's generated `Bundle.module` only searches the app
/// root and the absolute build path, and calls `fatalError` when neither
/// exists — so a shipped `.app` (resources in Contents/Resources, no build
/// directory) crashes on first use. Look in the app's resources first; keep
/// `Bundle.module` only as the fallback for `swift run` builds.
enum GhosttyResourceBundle {
    static let name = "GhosttyKit_GhosttyTerminal.bundle"

    static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name), let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()
}
