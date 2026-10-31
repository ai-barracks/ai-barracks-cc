import Foundation

/// Every tunable value of the PoC lives here so views and tests never embed
/// magic numbers or paths.
enum AppConstants {
    enum Paths {
        static let barracksRegistry = "~/.aib/barracks.json"
        static let rendererDirectory = "MarkdownRenderer"
        static let rendererEntry = "index.html"
        static let fixturesDirectory = "Fixtures"
        static let recorderScript = "pty_recorder.py"
        static let selectionScript = "selection_text.sh"
        static let python = "/usr/bin/python3"
        static let shell = "/bin/sh"
    }

    enum Environment {
        static let paneID = "AIBCC_PANE_ID"
        static let readyFile = "AIBCC_READY_FILE"
        static let signalFile = "AIBCC_SIGNAL_FILE"
        static let lang = "LANG"
        static let fallbackLocale = "en_US.UTF-8"
    }

    enum Terminal {
        static let fontFamily = "SF Mono"
        static let fallbackFontFamily = "Apple SD Gothic Neo"
        static let fontSize: Float = 13
        static let minimumContrast = 1.3
        /// Points. Self-test cell math depends on these exact values.
        static let paddingX = 8
        static let paddingY = 6
    }

    enum Layout {
        static let minWindowWidth: CGFloat = 960
        static let minWindowHeight: CGFloat = 600
        static let sidebarMinWidth: CGFloat = 200
        static let inspectorMinWidth: CGFloat = 320
        static let inspectorIdealWidth: CGFloat = 420
        static let paneSpacing: CGFloat = 1
    }

    enum Artifacts {
        static let listLimit = 50
        static let fileExtension = "md"
        static let excludedDirectories: Set<String> = [
            ".git", "node_modules", ".build", "dist", ".venv", ".claude", ".agents",
        ]
        /// Fixed barrack knowledge files have their own dedicated viewers.
        static let dedicatedViewerFiles: Set<String> = [
            "RULES.md", "SOUL.md", "GROWTH.md", "AGENTS.md", "CLAUDE.md", "GEMINI.md",
        ]
        static let watchLatency: TimeInterval = 0.3
        static let rendererReadyTimeout: Duration = .seconds(3)
    }

    enum SelfTest {
        static let argument = "--selftest"
        static let outputDirectoryEnv = "AIBCC_SELFTEST_OUT"
        static let defaultOutputDirectory = "~/Library/Application Support/AIBCCPoC/selftest"
        static let pollInterval: Duration = .milliseconds(25)
        static let eventDrain: Duration = .milliseconds(60)
        static let captureTimeout: Duration = .seconds(4)
        static let changeGrace: Duration = .milliseconds(500)
        /// Longer than Ghostty's multi-click interval so consecutive click
        /// tests are never counted as one double/triple click.
        static let clickReset: Duration = .milliseconds(700)
        static let readyTimeout: Duration = .seconds(10)
        static let settleTimeout: Duration = .seconds(3)
        static let stableWindow: Duration = .milliseconds(150)
        static let resizeConvergenceBudget: Duration = .milliseconds(300)
        static let resizeSteps = 20
        static let resizeLargeSize = CGSize(width: 1400, height: 900)
        static let resizeSmallSize = CGSize(width: 980, height: 620)
    }
}
