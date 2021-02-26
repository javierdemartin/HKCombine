// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "HKCombine",
    platforms: [.iOS(.v14), .watchOS(.v7)],
    products: [
        .library(
            name: "HKCombine",
            targets: ["HKCombine"]),
    ],
    targets: [
        .target(
            name: "HKCombine",
            dependencies: []),
        .testTarget(
            name: "HKCombineTests",
            dependencies: ["HKCombine"]),
    ]
)
