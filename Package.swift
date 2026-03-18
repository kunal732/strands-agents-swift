// swift-tools-version: 6.0

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "strands-agents-swift",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "StrandsAgents", targets: ["StrandsAgents"]),
        .library(name: "StrandsBedrockProvider", targets: ["StrandsBedrockProvider"]),
        .library(name: "StrandsMLXProvider", targets: ["StrandsMLXProvider"]),
        .library(name: "StrandsAnthropicProvider", targets: ["StrandsAnthropicProvider"]),
        .library(name: "StrandsOpenAIProvider", targets: ["StrandsOpenAIProvider"]),
        .library(name: "StrandsOTelObservability", targets: ["StrandsOTelObservability"]),
        .library(name: "StrandsBidiStreaming", targets: ["StrandsBidiStreaming"]),
        .library(name: "StrandsMLXBidiProvider", targets: ["StrandsMLXBidiProvider"]),
        .library(name: "StrandsGeminiProvider", targets: ["StrandsGeminiProvider"]),
    ],
    dependencies: [
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", .upToNextMajor(from: "1.0.0")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm/", .upToNextMajor(from: "2.30.3")),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", .upToNextMajor(from: "1.0.0")),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.30.6")),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
    ],
    targets: [
        // Core
        .target(
            name: "StrandsAgents",
            dependencies: ["StrandsAgentsMacros"],
            path: "Sources/StrandsAgents"
        ),

        // Macro implementation (compiler plugin)
        .macro(
            name: "StrandsAgentsMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ],
            path: "Sources/StrandsAgentsMacros"
        ),

        // Model Providers
        .target(
            name: "StrandsBedrockProvider",
            dependencies: [
                "StrandsAgents",
                .product(name: "AWSBedrockRuntime", package: "aws-sdk-swift"),
            ],
            path: "Sources/StrandsBedrockProvider"
        ),
        .target(
            name: "StrandsMLXProvider",
            dependencies: [
                "StrandsAgents",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Sources/StrandsMLXProvider"
        ),
        .target(
            name: "StrandsAnthropicProvider",
            dependencies: ["StrandsAgents"],
            path: "Sources/StrandsAnthropicProvider"
        ),
        .target(
            name: "StrandsOpenAIProvider",
            dependencies: ["StrandsAgents"],
            path: "Sources/StrandsOpenAIProvider"
        ),
        .target(
            name: "StrandsGeminiProvider",
            dependencies: ["StrandsAgents"],
            path: "Sources/StrandsGeminiProvider"
        ),

        // Observability
        .target(
            name: "StrandsOTelObservability",
            dependencies: [
                "StrandsAgents",
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift"),
                .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
            ],
            path: "Sources/StrandsOTelObservability"
        ),

        // Bidi Streaming (core protocols + cloud models)
        .target(
            name: "StrandsBidiStreaming",
            dependencies: [
                "StrandsAgents",
                .product(name: "AWSBedrockRuntime", package: "aws-sdk-swift"),
            ],
            path: "Sources/StrandsBidiStreaming"
        ),

        // Bidi MLX Provider (local STT + LLM + TTS pipeline)
        .target(
            name: "StrandsMLXBidiProvider",
            dependencies: [
                "StrandsAgents",
                "StrandsBidiStreaming",
                "StrandsMLXProvider",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),
            ],
            path: "Sources/StrandsMLXBidiProvider"
        ),

        // Examples
        .executableTarget(
            name: "LocalInferenceExample",
            dependencies: ["StrandsAgents", "StrandsMLXProvider"],
            path: "Examples/LocalInference"
        ),
        .executableTarget(
            name: "BedrockInferenceExample",
            dependencies: ["StrandsAgents", "StrandsBedrockProvider"],
            path: "Examples/BedrockInference"
        ),
        .executableTarget(
            name: "MenuBarAgent",
            dependencies: ["StrandsAgents", "StrandsMLXProvider", "StrandsBedrockProvider", "StrandsBidiStreaming"],
            path: "Examples/MenuBarAgent"
        ),

        // Tests
        .testTarget(
            name: "StrandsAgentsTests",
            dependencies: ["StrandsAgents"],
            path: "Tests/StrandsAgentsTests"
        ),
    ]
)
