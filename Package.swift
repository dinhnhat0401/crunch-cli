// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "crunch-cli",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrunchCore", targets: ["CrunchCore"]),
        .executable(name: "crunch", targets: ["crunch"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "CrunchCore",
            path: "Sources/CrunchCore"
        ),
        .executableTarget(
            name: "crunch",
            dependencies: [
                "CrunchCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/crunch"
        ),
        .testTarget(
            name: "CrunchCoreTests",
            dependencies: ["CrunchCore"],
            path: "Tests/CrunchCoreTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .testTarget(
            name: "CrunchCLITests",
            dependencies: ["crunch"],
            path: "Tests/CrunchCLITests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
