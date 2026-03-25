import Foundation
import AWSBedrockRuntime
import Smithy

/// AWS Bedrock model provider for cloud-based inference.
///
/// ```swift
/// let provider = BedrockProvider(config: BedrockConfig(
///     modelId: "anthropic.claude-sonnet-4-20250514",
///     region: "us-east-1"
/// ))
/// let agent = Agent(model: provider, tools: [MyTool()])
/// ```
public final class BedrockProvider: ModelProvider, @unchecked Sendable {
    public var modelId: String? { config.modelId }

    private var config: BedrockConfig
    private let client: BedrockRuntimeClient

    /// Create a Bedrock provider with the given configuration.
    ///
    /// Authentication uses the standard AWS credential chain
    /// (environment variables, ~/.aws/credentials, IAM role, etc.).
    public init(config: BedrockConfig = BedrockConfig()) throws {
        self.config = config

        let clientConfig = try BedrockRuntimeClient.BedrockRuntimeClientConfiguration(
            region: config.region
        )
        self.client = BedrockRuntimeClient(config: clientConfig)
    }

    /// Create a Bedrock provider with just a model ID.
    public convenience init(modelId: String) throws {
        try self.init(config: BedrockConfig(modelId: modelId))
    }

    // MARK: - ModelProvider

    public func stream(
        messages: [Message],
        toolSpecs: [ToolSpec]?,
        systemPrompt: String?,
        toolChoice: ToolChoice?
    ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let input = try buildInput(
                        messages: messages,
                        toolSpecs: toolSpecs,
                        systemPrompt: systemPrompt,
                        toolChoice: toolChoice
                    )

                    let response = try await client.converseStream(input: input)

                    guard let stream = response.stream else {
                        continuation.finish()
                        return
                    }

                    for try await event in stream {
                        if let modelEvent = BedrockStreamAdapter.convert(event) {
                            continuation.yield(modelEvent)
                        }
                    }

                    continuation.finish()
                } catch let error as AWSBedrockRuntime.ThrottlingException {
                    continuation.finish(throwing: StrandsError.modelThrottled(
                        retryAfter: nil
                    ))
                } catch let error as AWSBedrockRuntime.ServiceUnavailableException {
                    continuation.finish(throwing: StrandsError.modelThrottled(
                        retryAfter: 5.0
                    ))
                } catch let error as AWSBedrockRuntime.ModelErrorException {
                    continuation.finish(throwing: StrandsError.providerError(
                        underlying: error
                    ))
                } catch {
                    continuation.finish(throwing: StrandsError.providerError(
                        underlying: error
                    ))
                }
            }
        }
    }

    // MARK: - Private

    private func buildInput(
        messages: [Message],
        toolSpecs: [ToolSpec]?,
        systemPrompt: String?,
        toolChoice: ToolChoice?
    ) throws -> ConverseStreamInput {
        let bedrockMessages = BedrockTypeConverter.convertMessages(messages)

        var system: [BedrockRuntimeClientTypes.SystemContentBlock]?
        if let prompt = systemPrompt {
            system = [.text(prompt)]
        }

        var toolConfig: BedrockRuntimeClientTypes.ToolConfiguration?
        if let specs = toolSpecs, !specs.isEmpty {
            toolConfig = BedrockRuntimeClientTypes.ToolConfiguration(
                toolChoice: BedrockTypeConverter.convertToolChoice(toolChoice),
                tools: BedrockTypeConverter.convertToolSpecs(specs)
            )
        }

        var inferenceConfig = BedrockRuntimeClientTypes.InferenceConfiguration()
        inferenceConfig.maxTokens = config.maxTokens
        if let temp = config.temperature {
            inferenceConfig.temperature = Float(temp)
        }
        if let topP = config.topP {
            inferenceConfig.topp = Float(topP)
        }
        if let stops = config.stopSequences {
            inferenceConfig.stopSequences = stops
        }

        return ConverseStreamInput(
            inferenceConfig: inferenceConfig,
            messages: bedrockMessages,
            modelId: config.modelId,
            system: system,
            toolConfig: toolConfig
        )
    }
}
