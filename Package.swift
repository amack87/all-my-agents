// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AllMyAgents",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/tmandry/AXSwift", from: "0.3.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.11.2"),
    ],
    targets: [
        .executableTarget(
            name: "AllMyAgents",
            dependencies: ["AXSwift", "SwiftTerm"],
            path: "Sources/AgentHub"
        )
    ]
)
