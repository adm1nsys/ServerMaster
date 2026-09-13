// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ServerMasterCLI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "servermaster", targets: ["servermaster"])
    ],
    targets: [
        .executableTarget(
            name: "servermaster",
            path: "Sources/servermaster"
        )
    ]
)
