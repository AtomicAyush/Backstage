// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Backstage",
    platforms: [
        // ScreenCaptureKit's one-shot screenshots arrived in macOS 14.
        .macOS("14.0")
    ],
    products: [
        .executable(name: "backstage", targets: ["backstage"]),
        .executable(name: "BackstageViewer", targets: ["BackstageViewer"]),
    ],
    targets: [
        // The only Objective-C: a thin runtime wrapper around CoreGraphics' private
        // CGVirtualDisplay classes, which Swift cannot declare on its own.
        .target(
            name: "CVirtualDisplay"
        ),
        // Everything an agent needs: its screen, its apps, input, capture, and the UI tree.
        // Accessibility and CoreGraphics event APIs predate strict concurrency, so this
        // target builds in Swift 5 mode to stay readable.
        .target(
            name: "BackstageCore",
            dependencies: ["CVirtualDisplay"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The CLI: `backstage mcp` is the MCP server agents talk to.
        .executableTarget(
            name: "backstage",
            dependencies: ["BackstageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu-bar app for watching, pausing, and taking over agent screens.
        .executableTarget(
            name: "BackstageViewer",
            dependencies: ["BackstageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BackstageCoreTests",
            dependencies: ["BackstageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
