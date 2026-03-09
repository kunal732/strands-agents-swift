/// The result of an agent invocation.
public struct AgentResult: Sendable {
    /// Why the agent stopped.
    public var stopReason: StopReason

    /// The final assistant message.
    public var message: Message

    /// Token usage across all model calls in this invocation.
    public var usage: Usage

    /// Number of loop cycles executed.
    public var cycleCount: Int

    /// Detailed per-cycle metrics for the invocation.
    public var metrics: EventLoopMetrics

    public init(
        stopReason: StopReason,
        message: Message,
        usage: Usage = Usage(),
        cycleCount: Int = 0,
        metrics: EventLoopMetrics = EventLoopMetrics()
    ) {
        self.stopReason = stopReason
        self.message = message
        self.usage = usage
        self.cycleCount = cycleCount
        self.metrics = metrics
    }
}

extension AgentResult: CustomStringConvertible {
    /// The concatenated text content from the final message.
    public var description: String {
        message.textContent
    }
}
