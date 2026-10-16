// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Eddy",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Eddy",
            path: "Sources/Eddy",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
