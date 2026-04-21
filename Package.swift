// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PasteMemo",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/lifedever/PermissionFlow.git",
            revision: "382510b731d5ad52682a504d657e256e7bd3d90d"
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
