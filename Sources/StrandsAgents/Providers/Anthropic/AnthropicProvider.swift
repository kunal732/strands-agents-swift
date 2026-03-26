import Foundation

/// Anthropic API model provider using the Messages API directly.
///
/// ```swift
/// let provider = AnthropicProvider(config: AnthropicConfig(
///     modelId: "claude-sonnet-4-20250514",
///     apiKey: "sk-ant-..."
/// ))
/// let agent = Agent(model: provider, tools: [MyTool()])
/// ```
///
/// If no API key is provided, reads from the `ANTHROPIC_API_KEY` environment variable.
public final class AnthropicProvider: ModelProvider, @unchecked Sendable {
    public var modelId: String? { config.modelId }
    public var genAISystem: String { "anthropic" }

    private var config: AnthropicConfig
    private let session: URLSession

    public init(config: AnthropicConfig = AnthropicConfig()) {
        self.config = config
        self.session = URLSession(configuration: .default)
    }

    /// Convenience initializer with just a model ID.
    public convenience init(modelId: String) {
        self.init(config: AnthropicConfig(modelId: modelId))
    }

    // MARK: - ModelProvider

    public func stream(
        messages: [Message],
        toolSpecs: [ToolSpec]?,
        systemPrompt: String?,
        toolChoice: ToolChoice?
    ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let config = self.config
        let session = self.session

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let apiKey = try config.resolvedApiKey()

                    // Build request
                    let body = AnthropicTypeConverter.buildRequestBody(
                        messages: messages,
                        modelId: config.modelId,
                        maxTokens: config.maxTokens,
                        systemPrompt: systemPrompt,
                        toolSpecs: toolSpecs,
                        toolChoice: toolChoice,
                        temperature: config.temperature,
                        topP: config.topP
                    )

                    let jsonData = try JSONSerialization.data(withJSONObject: body)

                    var request = URLRequest(url: URL(string: "\(config.baseURL)/v1/messages")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue(config.apiVersion, forHTTPHeaderField: "anthropic-version")
                    request.httpBody = jsonData

                    // Stream the response using URLSession bytes
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: StrandsError.providerError(
                            underlying: AnthropicProviderError.invalidResponse(statusCode: 0, body: "Not HTTP")
                        ))
                        return
                    }

                    // Handle non-200 responses
                    if httpResponse.statusCode == 429 {
                        let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after")
                            .flatMap(TimeInterval.init)
                        continuation.finish(throwing: StrandsError.modelThrottled(retryAfter: retryAfter))
                        return
                    }

                    if httpResponse.statusCode == 529 {
                        continuation.finish(throwing: StrandsError.modelThrottled(retryAfter: 5.0))
                        return
                    }

                    if httpResponse.statusCode != 200 {
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                        }
                        continuation.finish(throwing: StrandsError.providerError(
                            underlying: AnthropicProviderError.invalidResponse(
                                statusCode: httpResponse.statusCode,
                                body: errorBody
                            )
                        ))
                        return
                    }

                    // Parse SSE stream
                    var currentEventType = ""
                    var pendingStopReason: StopReason?

                    for try await line in bytes.lines {
                        if line.hasPrefix("event: ") {
                            currentEventType = String(line.dropFirst(7))
                            continue
                        }

                        if line.hasPrefix("data: ") {
                            let dataStr = String(line.dropFirst(6))

                            // Handle [DONE] or empty data
                            if dataStr == "[DONE]" { break }

                            guard let jsonData = dataStr.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                            else { continue }

                            // Handle message_start with usage
                            if currentEventType == "message_start",
                               let message = json["message"] as? [String: Any] {
                                continuation.yield(.messageStart(role: .assistant))
                                if let usageDict = message["usage"] as? [String: Any] {
                                    let usage = AnthropicTypeConverter.parseUsage(usageDict)
                                    continuation.yield(.metadata(usage: usage, metrics: nil))
                                }
                                continue
                            }

                            // Handle message_delta (contains stop_reason)
                            if currentEventType == "message_delta" {
                                if let delta = json["delta"] as? [String: Any],
                                   let stopReasonStr = delta["stop_reason"] as? String {
                                    pendingStopReason = AnthropicTypeConverter.parseStopReason(stopReasonStr)
                                }
                                if let usageDict = json["usage"] as? [String: Any] {
                                    let usage = AnthropicTypeConverter.parseUsage(usageDict)
                                    continuation.yield(.metadata(usage: usage, metrics: nil))
                                }
                                continue
                            }

                            // Handle message_stop
                            if currentEventType == "message_stop" {
                                let reason = pendingStopReason ?? .endTurn
                                continuation.yield(.messageStop(stopReason: reason))
                                continue
                            }

                            // All other events
                            if let event = AnthropicTypeConverter.parseStreamEvent(
                                eventType: currentEventType, data: json
                            ) {
                                continuation.yield(event)
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    if let strandsError = error as? StrandsError {
                        continuation.finish(throwing: strandsError)
                    } else {
                        continuation.finish(throwing: StrandsError.providerError(underlying: error))
                    }
                }
            }
        }
    }
}
