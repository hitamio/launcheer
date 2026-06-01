// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Launcheer",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Launcheer",
            path: "Sources/Launcheer"
        )
    ]
)
