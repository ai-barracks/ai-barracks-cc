// swift-tools-version: 6.2
import PackageDescription

// libghostty-spm is vendored at tag 2.2.2026103001; its binaryTarget keeps
// the prebuilt GhosttyKit xcframework (Ghostty upstream 1e9e14af5df1) pinned
// by checksum.
let package = Package(
    name: "AIBCCPoC",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Vendored libghostty-spm 2.2.2026103001 with a resource-bundle
        // lookup that works in a shipped .app (Vendor/libghostty-spm/PATCHES.md).
        .package(path: "Vendor/libghostty-spm"),
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
        // Drives other apps with real input events for baselines (needs
        // Accessibility; launched with `open` as its own app).
        .executableTarget(
            name: "AIBCCBench",
            path: "Sources/AIBCCBench",
            linkerSettings: [.linkedFramework("ApplicationServices"), .linkedFramework("AppKit")]
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
