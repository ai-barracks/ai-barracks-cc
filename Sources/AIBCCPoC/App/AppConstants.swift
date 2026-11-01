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
        static let floodScript = "flood_recorder.py"
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
        static let fontSize: Float = 13
        static let minimumContrast = 1.3
        /// Points. Self-test cell math depends on these exact values.
        static let paddingX = 8
        static let paddingY = 6
        /// App shortcuts that must win over Ghostty's default keybinds
        /// (Cmd+Opt+I is Ghostty's inspector toggle; found by IN-11b).
        static let appReservedChords = [
            "super+alt+i", "super+alt+1", "super+alt+2", "super+alt+4", "super+alt+shift+l",
        ]
    }

    /// Opt-in daemon PTY backend (persistence spike, known issue #4).
    enum Daemon {
        static let backendArgument = "--backend=daemon"
        static let socketArgumentPrefix = "--ptyd-socket="
        static let executableName = "AIBCCPtyDaemon"
        static let defaultSocket = "~/Library/Application Support/AIBCCPoC/ptyd.sock"
        static let sessionStoreSuffix = ".sessions.json"
        static let logSuffix = ".log"
        static let startTimeout: TimeInterval = 3
        static let startPollMicroseconds: useconds_t = 50_000
        static let replaySettleInitialDelay: Duration = .milliseconds(20)
        static let replaySettleMaxDelay: Duration = .seconds(1)
        /// The in-memory backend ships no xterm-ghostty terminfo to children.
        static let term = "xterm-256color"
        static let colorTerm = "truecolor"
        static let termProgram = "AIBCC"
        static let commandShell = "/bin/sh"
        static let fallbackLoginShell = "/bin/zsh"
        static let placeholderColumns: UInt16 = 80
        static let placeholderRows: UInt16 = 24
        /// Unparsed terminal output at which the app stops reading the
        /// daemon socket (end-to-end back-pressure down to the child).
        static let parseBacklogHighWater = 8 * 1024 * 1024
        static let parseBacklogLowWater = 2 * 1024 * 1024
        /// Split drags change the grid on every mouse move; save after.
        static let persistDebounce: Duration = .milliseconds(400)
    }

    enum Layout {
        static let minWindowWidth: CGFloat = 960
        static let minWindowHeight: CGFloat = 600
        static let sidebarMinWidth: CGFloat = 200
        static let defaultWindowWidth: CGFloat = 1440
        static let defaultWindowHeight: CGFloat = 900
        static let inspectorMinWidth: CGFloat = 300
        static let inspectorIdealWidth: CGFloat = 360
        static let artifactListMinHeight: CGFloat = 90
        static let artifactListIdealHeight: CGFloat = 150
        static let artifactListMaxHeight: CGFloat = 260
        static let artifactDocumentMinHeight: CGFloat = 240
        static let paneSpacing: CGFloat = 1
        static let dividerHitWidth: CGFloat = 8
        static let focusHandoffAttempts = 40
        static let splitRatioRange: ClosedRange<CGFloat> = 0.2...0.8
    }

    enum Artifacts {
        static let listLimit = 50
        static let fileExtension = "md"
        static let excludedDirectories: Set<String> = [
            ".git", "node_modules", ".build", "dist", ".venv", ".claude", ".agents",
        ]
        /// Fixed barrack knowledge files have their own dedicated viewers.
        static let dedicatedViewerFiles: Set<String> = [
            "RULES.md", "SOUL.md", "GROWTH.md", "AGENTS.md", "CLAUDE.md", "GEMINI.md", "SESSIONS.md",
        ]
        static let watchLatency: TimeInterval = 0.3
        static let rendererReadyTimeout: Duration = .seconds(3)
    }

    enum SelfTest {
        static let argument = "--selftest"
        static let onlyArgumentPrefix = "--selftest-only="
        /// Set by scripts/verify-standalone.sh: the build-path resource
        /// bundle it moved aside (PK-01b).
        static let standaloneArgumentPrefix = "--standalone-check="
        static let outputDirectoryEnv = "AIBCC_SELFTEST_OUT"
        static let defaultOutputDirectory = "~/Library/Application Support/AIBCCPoC/selftest"
        static let pollInterval: Duration = .milliseconds(25)
        static let captureTimeout: Duration = .seconds(4)
        static let captureRenderGrace: Duration = .milliseconds(250)
        static let changeGrace: Duration = .milliseconds(500)
        /// Longer than Ghostty's multi-click interval so consecutive click
        /// tests are never counted as one double/triple click.
        static let clickReset: Duration = .milliseconds(700)
        static let minimumChildRuntime: Duration = .seconds(1)
        /// ST-02 pre-registered candidate (final value after the v1.6.1 baseline).
        static let latencyP95BudgetMs = 50.0
        static let latencySamples = 80
        static let latencyKeyInterval: Duration = .milliseconds(6)
        static let latencyMinimumValidSamples = 15
        static let readyTimeout: Duration = .seconds(10)
        static let settleTimeout: Duration = .seconds(3)
        static let stableWindow: Duration = .milliseconds(150)
        static let resizeConvergenceBudget: Duration = .milliseconds(300)
        static let resizeSteps = 20
        static let resizeLargeSize = CGSize(width: 1400, height: 900)
        static let resizeSmallSize = CGSize(width: 980, height: 620)
    }
}
