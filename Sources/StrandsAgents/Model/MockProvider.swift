import Foundation

/// A model provider for testing that returns pre-configured responses.
///
/// ```swift
/// let mock = MockProvider(responses: [
///     .text("Hello! Let me help you."),
///     .toolUse(name: "calculator", input: ["expression": "2+2"]),
///     .text("The answer is 4."),
/// ])
/// let agent = Agent(model: mock, tools: [calculatorTool])
/// ```
public final class MockProvider: ModelProvider, @unchecked Sendable {
    public let modelId: String?

    private let lock = NSLock()
    private var responses: [MockResponse]
    private var callIndex = 0

    /// All messages received across calls, for test assertions.
    public private(set) var receivedMessages: [[Message]] = []

    public init(modelId: String? = "mock-model", responses: [MockResponse]) {
        self.modelId = modelId
        self.responses = responses
    }

    /// Convenience for a single text response.
    public convenience init(response: String) {
        self.init(responses: [.text(response)])
    }

    public func stream(
        messages: [Message],
        toolSpecs: [ToolSpec]?,
        systemPrompt: String?,
        toolChoice: ToolChoice?
    ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let response: MockResponse
        lock.lock()
        receivedMessages.append(messages)
        if callIndex < responses.count {
            response = responses[callIndex]
            callIndex += 1
        } else {
            response = .text("[MockProvider: no more responses configured]")
        }
        lock.unlock()

        return AsyncThrowingStream { continuation in
            continuation.yield(.messageStart(role: .assistant))

            switch response {
            case .text(let text):
                continuation.yield(.contentBlockStart(ContentBlockStartData()))
                // Stream text in chunks for realistic streaming simulation
                let chunkSize = max(1, text.count / 3)
                var offset = text.startIndex
                while offset < text.endIndex {
                    let end = text.index(offset, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
                    let chunk = String(text[offset..<end])
                    continuation.yield(.contentBlockDelta(.text(chunk)))
                    offset = end
                }
                continuation.yield(.contentBlockStop)
                continuation.yield(.messageStop(stopReason: .endTurn))

            case .toolUse(let name, let toolUseId, let input):
                continuation.yield(.contentBlockStart(ContentBlockStartData(
                    toolUse: ToolUseStart(toolUseId: toolUseId, name: name)
                )))
                if let inputData = try? JSONEncoder().encode(input),
                   let inputString = String(data: inputData, encoding: .utf8) {
                    continuation.yield(.contentBlockDelta(.toolUseInput(inputString)))
                }
                continuation.yield(.contentBlockStop)
                continuation.yield(.messageStop(stopReason: .toolUse))

            case .multipleToolUses(let toolUses):
                for tu in toolUses {
                    continuation.yield(.contentBlockStart(ContentBlockStartData(
                        toolUse: ToolUseStart(toolUseId: tu.toolUseId, name: tu.name)
                    )))
                    if let inputData = try? JSONEncoder().encode(tu.input),
                       let inputString = String(data: inputData, encoding: .utf8) {
                        continuation.yield(.contentBlockDelta(.toolUseInput(inputString)))
                    }
                    continuation.yield(.contentBlockStop)
                }
                continuation.yield(.messageStop(stopReason: .toolUse))

            case .error(let error):
                continuation.finish(throwing: error)
                return

            case .throttled(let retryAfter):
                continuation.finish(throwing: StrandsError.modelThrottled(retryAfter: retryAfter))
                return
            }

            continuation.yield(.metadata(
                usage: Usage(inputTokens: 10, outputTokens: 20, totalTokens: 30),
                metrics: nil
            ))
            continuation.finish()
        }
    }

    /// Reset the call index to replay responses.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        callIndex = 0
        receivedMessages = []
    }
}

// MARK: - MockResponse

/// A pre-configured response for `MockProvider`.
public enum MockResponse: Sendable {
    /// Respond with text content.
    case text(String)

    /// Respond with a single tool use request.
    case toolUse(name: String, toolUseId: String = UUID().uuidString, input: JSONValue = .object([:]))

    /// Respond with multiple tool use requests in one message.
    case multipleToolUses([MockToolUse])

    /// Throw an error.
    case error(StrandsError)

    /// Simulate throttling.
    case throttled(retryAfter: TimeInterval?)
}

/// A tool use entry for `MockResponse.multipleToolUses`.
public struct MockToolUse: Sendable {
    public var name: String
    public var toolUseId: String
    public var input: JSONValue

    public init(name: String, toolUseId: String = UUID().uuidString, input: JSONValue = .object([:])) {
        self.name = name
        self.toolUseId = toolUseId
        self.input = input
    }
}
