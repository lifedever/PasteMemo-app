// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PasteMemo",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/lifedever/PermissionFlow.git",
            revision: "6678e78b49edb95cc00b6d6754ca1e6954b65fbc"
        ),
    ],
    targets: [
        .executableTarget(
            name: "PasteMemo",
            dependencies: [
                .product(name: "PermissionFlow", package: "PermissionFlow"),
            ],
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
