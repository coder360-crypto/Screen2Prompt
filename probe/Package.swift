// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpeechProbe",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "SpeechProbe", path: "Sources/SpeechProbe",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "IconSheet", path: "Sources/IconSheet",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
