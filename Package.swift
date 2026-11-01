// swift-tools-version: 6.2
import PackageDescription

// libghostty-spm is pinned to an exact tag so the prebuilt GhosttyKit
// xcframework (Ghostty upstream 1e9e14af5df1) stays reproducible.
let package = Package(
    name: "AIBCCPoC",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/Lakr233/libghostty-spm.git",
            exact: "2.2.2026103001"
        ),
    ],
    targets: [
        // Frame protocol + socket helpers shared by the app and the daemon.
        .target(name: "PtyProtocol", path: "Sources/PtyProtocol"),
        // PTY owner that outlives the app (Herdr-style core daemon).
        .executableTarget(
            name: "AIBCCPtyDaemon",
            dependencies: ["PtyProtocol"],
            path: "Sources/PtyDaemon"
        ),
        .executableTarget(
            name: "AIBCCPoC",
            dependencies: [
                "PtyProtocol",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            path: "Sources/AIBCCPoC",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
    ]
    // swift-tools-version 6.x defaults every target to the Swift 6 language mode.
)
