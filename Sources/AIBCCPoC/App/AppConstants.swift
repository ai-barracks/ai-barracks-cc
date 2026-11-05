import Foundation

/// Every tunable value of the PoC lives here so views and tests never embed
/// magic numbers or paths.
enum AppConstants {
    enum Paths {
        /// aib's registry; `AIB_REGISTRY` points elsewhere, as it does for
        /// aib itself (demo data, isolated runs).
        static var barracksRegistry: String {
            ProcessInfo.processInfo.environment["AIB_REGISTRY"].flatMap { $0.isEmpty ? nil : $0 } ?? "~/.aib/barracks.json"
        }
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
            "super+n", "super+shift+a", "super+shift+c", "super+k",
        ]
    }

    /// Opt-in daemon PTY backend (persistence spike, known issue #4).
    enum Daemon {
        /// The daemon backend is the default (spec v1 decision 2).
        static let execArgument = "--backend=exec"
        static let backendArgument = "--backend=daemon"
        static let socketArgumentPrefix = "--ptyd-socket="
        static let executableName = "AIBCCPtyDaemon"
        /// The release app keeps its own folder (socket, saved layout,
        /// archive); the development build (self-tests, bench) keeps AIBCCPoC,
        /// so the two never share a daemon.
        static var supportDirectory: String {
            Bundle.main.bundleIdentifier == Release.bundleIdentifier
                ? "~/Library/Application Support/\(Release.supportFolder)" : "~/Library/Application Support/AIBCCPoC"
        }
        /// Self-tests never touch the user's sessions or saved layout.
        static let selfTestSocketName = "ptyd-selftest.sock"
        static let keepSessionsOnQuitKey = "keepSessionsOnQuit"
        static let sessionStoreSuffix = ".sessions.json"
        static let logSuffix = ".log"
        static let startTimeout: TimeInterval = 3
        /// A daemon from before HELLO never answers it.
        static let helloTimeout: Double = 1
        static let legacyInputRefusal = "input refused:"
        /// How long an "input refused" warning stays on a pane.
        static let noticeDuration: Duration = .seconds(6)
        static let startPollMicroseconds: useconds_t = 50_000
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

    enum Maintenance {
        static let aibWriteLockPrefix = "aib-write-"
        /// Shared by the development and release apps (they write the same
        /// registry); self-tests keep theirs in their own support folder.
        static let sharedSupportDirectory = "~/Library/Application Support/AIBarracks"
        static let aibWriteLockPoll: Duration = .milliseconds(100)
    }

    enum Health {
        static let firstCheckDelay: Duration = .seconds(10)
        static let interval: TimeInterval = 30
        static let toastLifetime: Duration = .seconds(10)
        static let maxToasts = 4
    }

    enum Documents {
        static let ruleFiles = ["RULES.md", "SOUL.md", "GROWTH.md", "agent.yaml"]
        static let listWidth: CGFloat = 220
        static let historyListWidth: CGFloat = 300
    }

    enum Liveness {
        static let refreshInterval: TimeInterval = 2
        /// done/crashed ring only this long after the event (seconds).
        static let attentionWindow = 12 * 3600
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

    /// The shipped v2 identity (scripts/package-app.sh VARIANT=release).
    enum Release {
        static let bundleIdentifier = "com.aibarracks.commandcenter2"
        static let supportFolder = "CommandCenter2"
    }

    enum Activation {
        /// v1's support directory: v1 and v2 share activation.json and its lock.
        static var directory: URL {
            URL(fileURLWithPath: ("~/Library/Application Support/com.aibarracks.commandcenter" as NSString).expandingTildeInPath)
        }
    }

    /// Terminal output archive (v1 scrollback.rs defaults).
    enum Scrollback {
        static let directory = "scrollback"
        static let selfTestDirectory = "scrollback-selftest"
        static let maxBytesPerOutput = 1024 * 1024
        static let maxTotalBytes = 100 * 1024 * 1024
        static let retention: TimeInterval = 14 * 24 * 60 * 60
        static let gcInterval: TimeInterval = 60
    }

    enum Git {
        /// Changes listed in the Git destination (the counts cover all).
        static let visibleChanges = 200
    }

    enum ChildProcess {
        /// From the start, not from the end of the output: a descendant that
        /// keeps the pipe open must not hold a caller forever (r5).
        static let timeout: TimeInterval = 300
        static let outputLimit = 16 * 1024 * 1024
        /// Timed out or cancelled: the exit status is unknown.
        static let unknownStatus: Int32 = -2
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
        /// A probe child (SelfTestProbe) gets this long before it counts as hung.
        static let probeTimeout: TimeInterval = 40
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
