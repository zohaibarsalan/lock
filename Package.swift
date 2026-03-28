// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Lock",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Lock",
            targets: ["Lock"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Lock",
            path: "Sources/Lock"
        )
    ]
)
