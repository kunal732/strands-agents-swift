import Foundation
import MLXLMCommon
import MLXLLM

/// Local model provider using MLX for on-device inference on Apple Silicon.
///
/// ```swift
/// let provider = MLXProvider(config: MLXConfig(
///     modelId: "mlx-community/Qwen3.5-9B-MLX-4bit"
/// ))
/// let agent = Agent(model: provider)
/// let result = try await agent.run("Hello!")
/// ```
///
/// Supports tool calling with models that have tool-calling chat templates (e.g. Qwen).
///
/// - Note: MLX inference is only available on macOS with Apple Silicon.
public final class MLXProvider: ModelProvider, @unchecked Sendable {
    public var modelId: String? { config.modelId }
    public var genAISystem: String { "mlx" }

    private let config: MLXConfig
    private let loader: MLXModelLoader

    public init(config: MLXConfig = MLXConfig()) {
        self.config = config
        self.loader = MLXModelLoader.shared
    }

    /// Convenience initializer with just a model ID.
    public convenience init(modelId: String) {
        self.init(config: MLXConfig(modelId: modelId))
    }

    // MARK: - ModelProvider

    public func stream(
        messages: [StrandsAgents.Message],
        toolSpecs: [StrandsAgents.ToolSpec]?,
        systemPrompt: String?,
        toolChoice: ToolChoice?
    ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let config = self.config
        let loader = self.loader

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let container = try await loader.load(modelId: config.modelId)

                    // Build chat messages
                    let chatMessages = MLXStreamAdapter.buildChatMessages(
                        from: messages,
                        systemPrompt: systemPrompt
                    )

                    // Convert tool specs to MLX format
                    let mlxToolSpecs = MLXStreamAdapter.convertToolSpecs(toolSpecs)

                    // Prepare input with tools
                    let userInput = UserInput(
                        prompt: .messages(chatMessages),
                        tools: mlxToolSpecs
                    )
                    let lmInput = try await container.prepare(input: userInput)

                    // Build generation parameters
                    var params = GenerateParameters()
                    params.maxTokens = config.maxTokens
                    params.temperature = Float(config.temperature)
                    params.topP = Float(config.topP)
                    if let rp = config.repetitionPenalty {
                        params.repetitionPenalty = Float(rp)
                    }
                    if let rcs = config.repetitionContextSize {
                        params.repetitionContextSize = rcs
                    }

                    // Emit stream start
                    continuation.yield(.messageStart(role: .assistant))

                    var outputTokenCount = 0
                    var inputTokenCount = 0
                    var hasToolCalls = false
                    var textStarted = false

                    // Generate tokens
                    let stream = try await container.generate(input: lmInput, parameters: params)

                    for await generation in stream {
                        switch generation {
                        case .chunk(let text):
                            outputTokenCount += 1
                            if !text.isEmpty {
                                if !textStarted && !hasToolCalls {
                                    continuation.yield(.contentBlockStart(ContentBlockStartData()))
                                    textStarted = true
                                }
                                if textStarted {
                                    continuation.yield(.contentBlockDelta(.text(text)))
                                }
                            }

                        case .info(let info):
                            inputTokenCount = info.promptTokenCount

                        case .toolCall(let call):
                            // Close any open text block
                            if textStarted {
                                continuation.yield(.contentBlockStop)
                                textStarted = false
                            }

                            hasToolCalls = true
                            let toolUseId = UUID().uuidString

                            // Emit tool use as content block
                            continuation.yield(.contentBlockStart(ContentBlockStartData(
                                toolUse: ToolUseStart(
                                    toolUseId: toolUseId,
                                    name: call.function.name
                                )
                            )))

                            // Convert arguments to JSON string
                            let argsValue = convertMLXArgsToJSONValue(call.function.arguments)
                            if let data = try? JSONEncoder().encode(argsValue),
                               let str = String(data: data, encoding: .utf8) {
                                continuation.yield(.contentBlockDelta(.toolUseInput(str)))
                            }

                            continuation.yield(.contentBlockStop)
                        }
                    }

                    // Close any open text block
                    if textStarted {
                        continuation.yield(.contentBlockStop)
                    }

                    // Determine stop reason
                    let stopReason: StopReason = hasToolCalls ? .toolUse : .endTurn

                    continuation.yield(.messageStop(stopReason: stopReason))
                    continuation.yield(.metadata(
                        usage: Usage(
                            inputTokens: inputTokenCount,
                            outputTokens: outputTokenCount,
                            totalTokens: inputTokenCount + outputTokenCount
                        ),
                        metrics: nil
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: StrandsError.providerError(underlying: error))
                }
            }
        }
    }

    /// Preload the model into memory.
    public func preload() async throws {
        _ = try await loader.load(modelId: config.modelId)
    }

    /// Evict the model from cache to free memory.
    public func evict() async {
        await loader.evict(modelId: config.modelId)
    }

    // MARK: - Private

    /// Convert MLX's JSONValue arguments to our JSONValue type.
    private func convertMLXArgsToJSONValue(
        _ args: [String: MLXLMCommon.JSONValue]
    ) -> StrandsAgents.JSONValue {
        var result: [String: StrandsAgents.JSONValue] = [:]
        for (key, value) in args {
            result[key] = convertMLXJSONValue(value)
        }
        return .object(result)
    }

    private func convertMLXJSONValue(_ value: MLXLMCommon.JSONValue) -> StrandsAgents.JSONValue {
        switch value {
        case .null:
            return .null
        case .bool(let v):
            return .bool(v)
        case .int(let v):
            return .int(v)
        case .double(let v):
            return .double(v)
        case .string(let v):
            return .string(v)
        case .array(let arr):
            return .array(arr.map { convertMLXJSONValue($0) })
        case .object(let dict):
            return .object(dict.mapValues { convertMLXJSONValue($0) })
        }
    }
}
