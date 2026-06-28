// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GoelDownloader",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GoelCore", targets: ["GoelCore"]),
        .executable(name: "GoelDownloader", targets: ["GoelApp"]),
    ],
    dependencies: [
        // GRDB is added in the persistence phase.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "GoelCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "GoelApp",
            dependencies: ["GoelCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "GoelCoreTests",
            dependencies: ["GoelCore"]
        ),
    ]
)
