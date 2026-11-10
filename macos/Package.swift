// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Reprise",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Reprise", targets: ["Reprise"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "Reprise",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Reprise",
            linkerSettings: [.linkedLibrary("sqlite3"), .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "RepriseTests",
            dependencies: ["Reprise"],
            path: "Tests/RepriseTests"
        )
    ]
)
