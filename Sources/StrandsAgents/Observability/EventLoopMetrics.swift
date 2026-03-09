import Foundation

/// Detailed metrics collected during a single agent loop cycle.
///
/// Each cycle (model call + optional tool execution) produces one `CycleMetrics`.
/// The `EventLoopMetrics` aggregates all cycles for the full invocation.
public struct CycleMetrics: Sendable {
    /// Cycle number (1-based).
    public var cycleNumber: Int

    /// Token usage for this cycle's model call.
    public var usage: Usage

    /// Model invocation latency.
    public var modelLatencyMs: Int

    /// Time to first token from the model.
    public var timeToFirstTokenMs: Int?

    /// Number of tools executed in this cycle.
    public var toolsExecuted: Int

    /// Per-tool latencies in this cycle.
    public var toolLatencies: [String: Int]

    /// The stop reason for this cycle.
    public var stopReason: StopReason

    /// The model/provider ID used for this cycle.
    public var modelId: String?

    /// Whether this was a routing fallback.
    public var routingFallback: Bool

    public init(
        cycleNumber: Int = 0,
        usage: Usage = Usage(),
        modelLatencyMs: Int = 0,
        timeToFirstTokenMs: Int? = nil,
        toolsExecuted: Int = 0,
        toolLatencies: [String: Int] = [:],
        stopReason: StopReason = .endTurn,
        modelId: String? = nil,
        routingFallback: Bool = false
    ) {
        self.cycleNumber = cycleNumber
        self.usage = usage
        self.modelLatencyMs = modelLatencyMs
        self.timeToFirstTokenMs = timeToFirstTokenMs
        self.toolsExecuted = toolsExecuted
        self.toolLatencies = toolLatencies
        self.stopReason = stopReason
        self.modelId = modelId
        self.routingFallback = routingFallback
    }
}

/// Aggregated metrics for a complete agent invocation (all cycles).
public struct EventLoopMetrics: Sendable {
    /// Per-cycle metrics.
    public var cycles: [CycleMetrics]

    /// Total token usage across all cycles.
    public var totalUsage: Usage

    /// Total invocation time (wall clock).
    public var totalLatencyMs: Int

    /// Number of cycles executed.
    public var cycleCount: Int { cycles.count }

    /// Total tools executed across all cycles.
    public var totalToolsExecuted: Int {
        cycles.reduce(0) { $0 + $1.toolsExecuted }
    }

    /// Average model latency per cycle.
    public var averageModelLatencyMs: Int {
        guard !cycles.isEmpty else { return 0 }
        return cycles.reduce(0) { $0 + $1.modelLatencyMs } / cycles.count
    }

    /// Average time to first token.
    public var averageTimeToFirstTokenMs: Int? {
        let ttfts = cycles.compactMap(\.timeToFirstTokenMs)
        guard !ttfts.isEmpty else { return nil }
        return ttfts.reduce(0, +) / ttfts.count
    }

    /// Tokens per second (output tokens / total time).
    public var outputTokensPerSecond: Double {
        guard totalLatencyMs > 0 else { return 0 }
        return Double(totalUsage.outputTokens) / (Double(totalLatencyMs) / 1000.0)
    }

    public init(cycles: [CycleMetrics] = [], totalUsage: Usage = Usage(), totalLatencyMs: Int = 0) {
        self.cycles = cycles
        self.totalUsage = totalUsage
        self.totalLatencyMs = totalLatencyMs
    }
}

/// Hook event that carries full metrics after an invocation completes.
public struct MetricsEvent: HookEvent {
    public var metrics: EventLoopMetrics

    public init(metrics: EventLoopMetrics) {
        self.metrics = metrics
    }
}
