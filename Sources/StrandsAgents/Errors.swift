import Foundation

/// Errors thrown by the Strands SDK.
public enum StrandsError: Error, Sendable {
    /// The model was throttled. Retry after the given interval.
    case modelThrottled(retryAfter: TimeInterval?)

    /// The model reached the maximum token limit.
    case maxTokensReached(partialMessage: Message)

    /// The conversation exceeds the model's context window and cannot be reduced further.
    case contextWindowOverflow

    /// A requested tool was not found in the registry.
    case toolNotFound(name: String)

    /// A tool execution failed.
    case toolExecutionFailed(name: String, underlying: Error)

    /// The model provided invalid input for a tool.
    case invalidToolInput(name: String, reason: String)

    /// Content was filtered by a safety policy.
    case contentFiltered(reason: String?)

    /// Serialization or deserialization failed.
    case serializationFailed(underlying: Error)

    /// A model provider returned an error.
    case providerError(underlying: Error)

    /// The model router could not select a provider.
    case routingFailed(reason: String)

    /// The operation was cancelled.
    case cancelled
}

extension StrandsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .modelThrottled(let retryAfter):
            if let delay = retryAfter {
                return "Model throttled. Retry after \(delay)s."
            }
            return "Model throttled."
        case .maxTokensReached:
            return "Maximum token limit reached."
        case .contextWindowOverflow:
            return "Context window overflow: cannot reduce context further."
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .toolExecutionFailed(let name, let error):
            return "Tool '\(name)' failed: \(error.localizedDescription)"
        case .invalidToolInput(let name, let reason):
            return "Invalid input for tool '\(name)': \(reason)"
        case .contentFiltered(let reason):
            return "Content filtered: \(reason ?? "no reason provided")"
        case .serializationFailed(let error):
            return "Serialization failed: \(error.localizedDescription)"
        case .providerError(let error):
            return "Provider error: \(error.localizedDescription)"
        case .routingFailed(let reason):
            return "Routing failed: \(reason)"
        case .cancelled:
            return "Operation cancelled."
        }
    }
}
