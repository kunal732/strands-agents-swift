/// Maintains a sliding window of recent messages.
///
/// When the window is exceeded, the oldest messages are removed. Tool result content
/// in older messages is truncated to save tokens. Tool use / tool result pairs are
/// kept together to avoid orphaned references.
public struct SlidingWindowConversationManager: ConversationManager {
    /// Maximum number of messages to retain.
    public var windowSize: Int

    /// Maximum character length for tool result content before truncation.
    public var maxToolResultLength: Int

    public init(windowSize: Int = 40, maxToolResultLength: Int = 2000) {
        self.windowSize = windowSize
        self.maxToolResultLength = maxToolResultLength
    }

    public func applyManagement(messages: inout [Message]) async {
        guard messages.count > windowSize else { return }

        // Find the first valid trim point that doesn't split a tool use/result pair
        let excess = messages.count - windowSize
        var trimIndex = excess

        // Ensure we don't cut between a toolUse and its toolResult
        trimIndex = findSafeTrimPoint(in: messages, startingAt: trimIndex)

        messages.removeFirst(trimIndex)
    }

    public func reduceContext(messages: inout [Message], error: Error?) async throws {
        // First pass: truncate large tool results
        var reduced = false
        for i in messages.indices {
            let truncated = truncateToolResults(in: messages[i])
            if truncated != nil {
                messages[i] = truncated!
                reduced = true
            }
        }

        // Second pass: remove oldest messages
        if !reduced || messages.count > windowSize {
            let removeCount = max(2, messages.count / 4)
            let trimIndex = findSafeTrimPoint(in: messages, startingAt: removeCount)
            if trimIndex > 0 {
                messages.removeFirst(trimIndex)
                reduced = true
            }
        }

        if !reduced {
            throw StrandsError.contextWindowOverflow
        }
    }

    // MARK: - Private

    private func findSafeTrimPoint(in messages: [Message], startingAt index: Int) -> Int {
        var trimIndex = min(index, messages.count)

        // Don't trim into the middle of a tool use/result sequence.
        // If the message at trimIndex is a user message containing tool results,
        // keep the preceding assistant message with tool uses.
        while trimIndex > 0 && trimIndex < messages.count {
            let msg = messages[trimIndex]
            let hasToolResults = msg.content.contains { block in
                if case .toolResult = block { return true }
                return false
            }
            if msg.role == .user && hasToolResults {
                trimIndex -= 1
            } else {
                break
            }
        }

        return max(0, trimIndex)
    }

    private func truncateToolResults(in message: Message) -> Message? {
        var modified = false
        let newContent: [ContentBlock] = message.content.map { block in
            guard case .toolResult(var result) = block else { return block }
            let truncatedContent: [ToolResultContent] = result.content.map { content in
                if case .text(let text) = content, text.count > maxToolResultLength {
                    modified = true
                    let prefix = String(text.prefix(200))
                    let suffix = String(text.suffix(200))
                    return .text("\(prefix)\n...[truncated \(text.count - 400) chars]...\n\(suffix)")
                }
                return content
            }
            result.content = truncatedContent
            return .toolResult(result)
        }

        guard modified else { return nil }
        return Message(role: message.role, content: newContent)
    }
}
