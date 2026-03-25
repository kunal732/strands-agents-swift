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
        // Everything in one module: providers, observability, voice, local inference
        .library(name: "StrandsAgents", targets: ["StrandsAgents"]),

        // Opt-in: @Tool and @StructuredOutput macros (triggers Xcode trust prompt)
        .library(name: "StrandsAgentsToolMacros", targets: ["StrandsAgentsToolMacros"]),
    ],
    dependencies: [
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", .upToNextMajor(from: "1.0.0")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "2.30.3")),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", .upToNextMajor(from: "1.0.0")),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.30.6")),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
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

        // Opt-in macro declarations
        .target(
            name: "StrandsAgentsToolMacros",
            dependencies: ["StrandsAgents", "StrandsAgentsMacrosPlugin"],
            path: "Sources/StrandsAgentsToolMacros"
        ),

        // Macro compiler plugin
        .macro(
            name: "StrandsAgentsMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ],
            path: "Sources/StrandsAgentsMacros"
        ),

        // Examples
        .executableTarget(
            name: "LocalInferenceExample",
            dependencies: ["StrandsAgents"],
            path: "Examples/LocalInference"
        ),
        .executableTarget(
            name: "BedrockInferenceExample",
            dependencies: ["StrandsAgents"],
            path: "Examples/BedrockInference"
        ),
        .executableTarget(
            name: "MenuBarAgent",
            dependencies: ["StrandsAgents"],
            path: "Examples/MenuBarAgent"
        ),
        .executableTarget(
            name: "WritingAssistant",
            dependencies: ["StrandsAgents"],
            path: "Examples/WritingAssistant",
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "PersonalAssistant",
            dependencies: ["StrandsAgentsToolMacros", "StrandsAgents"],
            path: "Examples/PersonalAssistant",
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "DesktopAssistant",
            dependencies: ["StrandsAgents"],
            path: "Examples/DesktopAssistant",
            exclude: ["Info.plist"]
        ),

        // Samples
        .executableTarget(
            name: "Sample01-SimpleLocalAgent",
            dependencies: ["StrandsAgentsToolMacros", "StrandsAgents"],
            path: "Samples/01-SimpleLocalAgent"
        ),
        .executableTarget(
            name: "Sample02-SimpleBedrockAgent",
            dependencies: ["StrandsAgentsToolMacros", "StrandsAgents"],
            path: "Samples/02-SimpleBedrockAgent"
        ),
        .executableTarget(
            name: "Sample03-HybridAgent",
            dependencies: ["StrandsAgentsToolMacros", "StrandsAgents"],
            path: "Samples/03-HybridAgent"
        ),
        .executableTarget(
            name: "Sample04-NovaSonicBidi",
            dependencies: ["StrandsAgentsToolMacros", "StrandsAgents"],
            path: "Samples/04-NovaSonicBidi"
        ),
        .executableTarget(
            name: "Sample05-MLXBidiLocal",
            dependencies: ["StrandsAgentsToolMacros", "StrandsAgents"],
            path: "Samples/05-MLXBidiLocal"
        ),
        .executableTarget(
            name: "Sample06-MultiAgentGraph",
            dependencies: ["StrandsAgents"],
            path: "Samples/06-MultiAgentGraph"
        ),
        .executableTarget(
            name: "Sample07-MultiAgentSwarm",
            dependencies: ["StrandsAgentsToolMacros", "StrandsAgents"],
            path: "Samples/07-MultiAgentSwarm"
        ),
        .executableTarget(
            name: "Sample08-MultiProvider",
            dependencies: ["StrandsAgentsToolMacros", "StrandsAgents"],
            path: "Samples/08-MultiProvider"
        ),
        .executableTarget(
            name: "Sample09-StructuredOutput",
            dependencies: ["StrandsAgentsToolMacros", "StrandsAgents"],
            path: "Samples/09-StructuredOutput"
        ),
        .executableTarget(
            name: "Sample10-SessionPersistence",
            dependencies: ["StrandsAgents"],
            path: "Samples/10-SessionPersistence"
        ),
        .executableTarget(
            name: "Sample11-DatadogObservability",
            dependencies: ["StrandsAgentsToolMacros", "StrandsAgents"],
            path: "Samples/11-DatadogObservability"
        ),
        .executableTarget(
            name: "Sample12-MCPDesktopControl",
            dependencies: ["StrandsAgents"],
            path: "Samples/12-MCPDesktopControl"
        ),

        // Tests
        .testTarget(
            name: "StrandsAgentsTests",
            dependencies: ["StrandsAgents", "StrandsAgentsToolMacros"],
            path: "Tests/StrandsAgentsTests"
        ),
    ]
)
