// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NetKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "NetKit",
            targets: ["NetKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/tikhop/Logger.git", branch: "master")
    ],
    targets: [
        .target(
            name: "NetKit",
            dependencies: [
                .product(name: "Logger", package: "Logger")
            ],
            path: "Sources",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "NetKitTests",
            dependencies: ["NetKit"],
            path: "Tests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
