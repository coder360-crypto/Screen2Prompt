// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Screen2Prompt",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "Screen2Prompt", path: "Sources/Screen2Prompt",
                          swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
