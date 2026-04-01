// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PasteMemo",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PasteMemo",
            path: "Sources",
            resources: [
                .process("Localization"),
                .copy("Resources"),
            ]
        ),
        .testTarget(
            name: "PasteMemoTests",
            dependencies: ["PasteMemo"],
            path: "Tests"
        ),
    ]
)
