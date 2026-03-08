import Foundation

/// Aggregates raw `ModelStreamEvent`s into complete `ContentBlock`s and a final `Message`.
///
/// This mirrors the TypeScript SDK's `streamAggregated()` pattern, separating raw provider
/// streaming from framework-level block assembly.
public struct StreamAggregator: Sendable {
    public init() {}

    /// Result of aggregating a complete model response.
    public struct AggregatedResult: Sendable {
        public var message: Message
        public var stopReason: StopReason
        public var usage: Usage?
        public var metrics: InvocationMetrics?
    }

    /// Consume a stream of model events and produce content blocks as they complete.
    ///
    /// Returns the fully assembled message and stop reason.
    ///
    /// - Parameter stream: The raw model event stream.
    /// - Parameter onContentBlock: Called each time a content block finishes assembling.
    /// - Parameter onTextDelta: Called for each text delta (for live streaming to UI).
    /// - Returns: The aggregated result with complete message and metadata.
    public func aggregate(
        stream: AsyncThrowingStream<ModelStreamEvent, Error>,
        onContentBlock: (@Sendable (ContentBlock) async -> Void)? = nil,
        onTextDelta: (@Sendable (String) async -> Void)? = nil
    ) async throws -> AggregatedResult {
        var role: Role = .assistant
        var contentBlocks: [ContentBlock] = []
        var stopReason: StopReason = .endTurn
        var usage: Usage?
        var metrics: InvocationMetrics?

        // Accumulator state for the current content block
        var currentText = ""
        var currentToolUseId: String?
        var currentToolName: String?
        var currentToolInput = ""
        var currentReasoningText: String?
        var currentReasoningSignature: String?
        var currentCitations: [Citation] = []
        var blockType: BlockType = .unknown

        for try await event in stream {
            switch event {
            case .messageStart(let r):
                role = r

            case .contentBlockStart(let data):
                // Reset accumulators
                currentText = ""
                currentToolInput = ""
                currentToolUseId = nil
                currentToolName = nil
                currentReasoningText = nil
                currentReasoningSignature = nil
                currentCitations = []

                if let toolStart = data.toolUse {
                    blockType = .toolUse
                    currentToolUseId = toolStart.toolUseId
                    currentToolName = toolStart.name
                } else {
                    blockType = .text
                }

            case .contentBlockDelta(let delta):
                switch delta {
                case .text(let text):
                    currentText += text
                    blockType = .text
                    await onTextDelta?(text)
                case .toolUseInput(let input):
                    currentToolInput += input
                    blockType = .toolUse
                case .reasoning(let text, let signature):
                    if let text { currentReasoningText = (currentReasoningText ?? "") + text }
                    if let signature { currentReasoningSignature = signature }
                    blockType = .reasoning
                case .citations(let citations):
                    currentCitations.append(contentsOf: citations)
                    blockType = .citations
                }

            case .contentBlockStop:
                let block: ContentBlock
                switch blockType {
                case .text:
                    block = .text(TextBlock(text: currentText))
                case .toolUse:
                    let input = parseToolInput(currentToolInput)
                    block = .toolUse(ToolUseBlock(
                        toolUseId: currentToolUseId ?? "",
                        name: currentToolName ?? "",
                        input: input
                    ))
                case .reasoning:
                    block = .reasoning(ReasoningBlock(
                        text: currentReasoningText,
                        signature: currentReasoningSignature
                    ))
                case .citations:
                    block = .citations(CitationsBlock(citations: currentCitations))
                case .unknown:
                    block = .text(TextBlock(text: currentText))
                }
                contentBlocks.append(block)
                await onContentBlock?(block)
                blockType = .unknown

            case .messageStop(let reason):
                stopReason = reason

            case .metadata(let u, let m):
                usage = u
                metrics = m
            }
        }

        let message = Message(role: role, content: contentBlocks)
        return AggregatedResult(
            message: message,
            stopReason: stopReason,
            usage: usage,
            metrics: metrics
        )
    }

    // MARK: - Private

    private enum BlockType {
        case text, toolUse, reasoning, citations, unknown
    }

    private func parseToolInput(_ raw: String) -> JSONValue {
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .object([:])
        }
        return decoded
    }
}
