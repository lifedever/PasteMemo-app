// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PasteMemo",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/lifedever/PermissionFlow.git",
            from: "0.1.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "PasteMemo",
            dependencies: [
                .product(name: "PermissionFlow", package: "PermissionFlow"),
            ],
            path: "Sources",
            exclude: ["MCPProxy"],
            resources: [
                .process("Localization"),
                .copy("Resources"),
            ]
        ),
        .executableTarget(
            name: "pastememo-mcp",
            path: "Sources/MCPProxy"
        ),
        .testTarget(
            name: "PasteMemoTests",
            dependencies: ["PasteMemo"],
            path: "Tests"
        ),
    ]
)
