// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "strands-agents-swift",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "StrandsAgents", targets: ["StrandsAgents"]),
    ],
    targets: [
        .target(
            name: "StrandsAgents",
            path: "Sources/StrandsAgents"
        ),
        .testTarget(
            name: "StrandsAgentsTests",
            dependencies: ["StrandsAgents"],
            path: "Tests/StrandsAgentsTests"
        ),
    ]
)
