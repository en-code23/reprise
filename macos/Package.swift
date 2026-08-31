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
    targets: [
        .executableTarget(
            name: "Reprise",
            path: "Sources/Reprise"
        ),
        .testTarget(
            name: "RepriseTests",
            dependencies: ["Reprise"],
            path: "Tests/RepriseTests"
        )
    ]
)
