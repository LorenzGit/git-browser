// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitBrowser",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "GitBrowserCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "GitBrowser",
            dependencies: ["GitBrowserCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GitBrowserCoreTests",
            dependencies: ["GitBrowserCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
