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
        .executableTarget(
            name: "AIBCCPoC",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            path: "Sources/AIBCCPoC",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
    ]
    // swift-tools-version 6.x defaults every target to the Swift 6 language mode.
)
