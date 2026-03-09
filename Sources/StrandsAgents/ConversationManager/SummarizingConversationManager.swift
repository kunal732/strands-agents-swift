import Foundation

/// A conversation manager that summarizes old messages using the model.
///
/// When the conversation exceeds `windowSize`, the oldest messages beyond the window
/// are replaced with a summary message. This preserves context better than simply
/// dropping old messages.
///
/// ```swift
/// let agent = Agent(
///     model: provider,
///     conversationManager: SummarizingConversationManager(
///         provider: provider,
///         windowSize: 20
///     )
/// )
/// ```
public struct SummarizingConversationManager: ConversationManager {
    /// The model provider used to generate summaries.
    private let provider: any ModelProvider

    /// Maximum number of recent messages to keep unsummarized.
    public var windowSize: Int

    /// The prompt used to request a summary from the model.
    public var summaryPrompt: String

    public init(
        provider: any ModelProvider,
        windowSize: Int = 20,
        summaryPrompt: String = "Summarize the key points of the preceding conversation in 2-3 concise sentences. Focus on decisions made, information exchanged, and any pending tasks."
    ) {
        self.provider = provider
        self.windowSize = windowSize
        self.summaryPrompt = summaryPrompt
    }

    public func applyManagement(messages: inout [Message]) async {
        guard messages.count > windowSize else { return }

        let excess = messages.count - windowSize
        // Don't summarize if only a few messages over
        guard excess >= 4 else { return }

        let toSummarize = Array(messages.prefix(excess))
        let toKeep = Array(messages.suffix(windowSize))

        // Generate summary
        if let summary = await generateSummary(of: toSummarize) {
            let summaryMessage = Message.user("[Previous conversation summary: \(summary)]")
            messages = [summaryMessage] + toKeep
        }
    }

    public func reduceContext(messages: inout [Message], error: Error?) async throws {
        // More aggressive: summarize half the messages
        let halfCount = messages.count / 2
        guard halfCount >= 2 else {
            throw StrandsError.contextWindowOverflow
        }

        let toSummarize = Array(messages.prefix(halfCount))
        let toKeep = Array(messages.suffix(messages.count - halfCount))

        if let summary = await generateSummary(of: toSummarize) {
            let summaryMessage = Message.user("[Previous conversation summary: \(summary)]")
            messages = [summaryMessage] + toKeep
        } else {
            // Fallback: just drop old messages
            messages = toKeep
        }
    }

    // MARK: - Private

    private func generateSummary(of messages: [Message]) async -> String? {
        // Build a summary request
        var summaryMessages = messages
        summaryMessages.append(.user(summaryPrompt))

        let stream = provider.stream(
            messages: summaryMessages,
            toolSpecs: nil,
            systemPrompt: "You are a concise summarizer. Provide only the summary, nothing else.",
            toolChoice: nil
        )

        do {
            let result = try await StreamAggregator().aggregate(stream: stream)
            let text = result.message.textContent
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}
