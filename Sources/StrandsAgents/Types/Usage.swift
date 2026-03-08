/// Token usage metrics from a model invocation.
public struct Usage: Sendable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int
    public var cacheReadInputTokens: Int?
    public var cacheWriteInputTokens: Int?

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        totalTokens: Int = 0,
        cacheReadInputTokens: Int? = nil,
        cacheWriteInputTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
    }
}

/// Latency metrics from a model invocation.
public struct InvocationMetrics: Sendable, Codable {
    public var latencyMs: Int
    public var timeToFirstByteMs: Int?

    public init(latencyMs: Int = 0, timeToFirstByteMs: Int? = nil) {
        self.latencyMs = latencyMs
        self.timeToFirstByteMs = timeToFirstByteMs
    }
}
