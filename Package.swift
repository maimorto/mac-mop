// swift-tools-version: 6.0

import PackageDescription

// Local builds with only the Command Line Tools have no XCTest. Set
// MC_SWIFT_TESTING_ONLY=1 to drop the XCTest targets so `swift test` builds
// and runs just the Swift Testing suite; CI and Xcode users keep everything.
let swiftTestingOnly = Context.environment["MC_SWIFT_TESTING_ONLY"] == "1"

let xctestTargets: [Target] = swiftTestingOnly ? [] : [
    .target(
        name: "MacCleanerTestSupport",
        dependencies: ["MacCleanerKit"],
        path: "Tests/MacCleanerTestSupport"
    ),
    .testTarget(
        name: "MacCleanerTests",
        dependencies: ["MacCleaner", "MacCleanerKit", "MacCleanerTestSupport"],
        path: "Tests/MacCleanerTests"
    ),
    .testTarget(
        name: "MacCleanerKitTests",
        dependencies: ["MacCleanerKit", "MacCleanerTestSupport"],
        path: "Tests/MacCleanerKitTests"
    ),
]

let package = Package(
    name: "MacCleaner",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacCleaner", targets: ["MacCleaner"]),
        .executable(name: "MacCleanerMenu", targets: ["MacCleanerMenu"]),
        .library(name: "MacCleanerKit", targets: ["MacCleanerKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "MacCleaner",
            dependencies: [
                "MacCleanerKit",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/MacCleaner",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "MacCleanerMenu",
            dependencies: ["MacCleanerKit"],
            path: "Sources/MacCleanerMenu"
        ),
        .target(
            name: "MacCleanerKit",
            dependencies: [],
            path: "Sources/MacCleanerKit"
        ),
        // Swift Testing only (no XCTest): runs with just the Command Line Tools.
        .testTarget(
            name: "MacCleanerKitSwiftTests",
            dependencies: ["MacCleanerKit"],
            path: "Tests/MacCleanerKitSwiftTests"
        ),
    ] + xctestTargets
)
