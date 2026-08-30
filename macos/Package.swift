// swift-tools-version: 6.2
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
        )
    ]
)
