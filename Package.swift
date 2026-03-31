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
        // Everything in one module: providers, observability, voice, local inference
        .library(name: "StrandsAgents", targets: ["StrandsAgents"]),
    ],
    dependencies: [
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", .upToNextMajor(from: "1.0.0")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "2.30.3")),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", .upToNextMajor(from: "1.0.0")),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.30.6")),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main"),
    ],
    targets: [
        // Single unified module
        .target(
            name: "StrandsAgents",
            dependencies: [
                .product(name: "AWSBedrockRuntime", package: "aws-sdk-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift"),
                .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),
            ],
            path: "Sources/StrandsAgents"
        ),

        // Tests
        .testTarget(
            name: "StrandsAgentsTests",
            dependencies: ["StrandsAgents"],
            path: "Tests/StrandsAgentsTests"
        ),
    ]
)
