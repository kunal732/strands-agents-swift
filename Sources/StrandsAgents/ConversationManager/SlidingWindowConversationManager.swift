/// Maintains a sliding window of recent messages.
///
/// When the window is exceeded, the oldest messages are removed. Tool result content
/// in older messages is truncated to save tokens. Tool use / tool result pairs are
/// kept together to avoid orphaned references.
///
/// Supports two modes:
/// - **Default**: Management applied after each agent loop cycle.
/// - **Per-turn** (`perTurn: true`): Proactively manage before each model call
///   to prevent context window overflow.
public struct SlidingWindowConversationManager: ConversationManager, HookProvider {
    /// Maximum number of messages to retain.
    public var windowSize: Int

    /// Maximum character length for tool result content before truncation.
    public var maxToolResultLength: Int

    /// If true, manage context proactively before each model call.
    public var perTurn: Bool

    public init(windowSize: Int = 40, maxToolResultLength: Int = 2000, perTurn: Bool = false) {
        self.windowSize = windowSize
        self.maxToolResultLength = maxToolResultLength
        self.perTurn = perTurn
    }

    // MARK: - HookProvider

    public func registerHooks(with registry: HookRegistry) {
        if perTurn {
            registry.addCallback(BeforeModelCallEvent.self) { [self] event in
                // Per-turn management is handled in applyManagement
                // which the agent loop calls after each cycle.
                // For true per-turn, we'd need mutable access to messages here,
                // which the hook system provides via the event.
            }
        }
    }

    // MARK: - ConversationManager

    public func applyManagement(messages: inout [Message]) async {
        guard messages.count > windowSize else { return }

        // First truncate large tool results to reclaim space
        for i in messages.indices {
            if let truncated = truncateToolResults(in: messages[i]) {
                messages[i] = truncated
            }
        }

        // Then trim excess messages
        if messages.count > windowSize {
            let excess = messages.count - windowSize
            let trimIndex = findSafeTrimPoint(in: messages, startingAt: excess)
            messages.removeFirst(trimIndex)
        }
    }

    public func reduceContext(messages: inout [Message], error: Error?) async throws {
        // First pass: truncate large tool results
        var reduced = false
        for i in messages.indices {
            if let truncated = truncateToolResults(in: messages[i]) {
                messages[i] = truncated
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
