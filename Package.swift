// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Scriptoria",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "ScriptoriaCore", targets: ["ScriptoriaCore"]),
        .executable(name: "scriptoria", targets: ["ScriptoriaCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.1"),
    ],
    targets: [
        // Shared core library
        .target(
            name: "ScriptoriaCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/ScriptoriaCore"
        ),
        // CLI executable
        .executableTarget(
            name: "ScriptoriaCLI",
            dependencies: [
                "ScriptoriaCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ScriptoriaCLI"
        ),
        // Tests
        .testTarget(
            name: "ScriptoriaCoreTests",
            dependencies: ["ScriptoriaCore", "ScriptoriaCLI"],
            path: "Tests/ScriptoriaCoreTests"
        ),
    ]
)
