import Foundation

/// Abstract interface for agent observability and tracing.
///
/// All agent loop iterations, model calls, tool calls, and routing decisions
/// are instrumented through this interface.
public protocol ObservabilityEngine: Sendable {
    /// Start a new span.
    func startSpan(name: String, attributes: [String: String]) -> SpanContext

    /// End a span.
    func endSpan(_ context: SpanContext, status: SpanStatus)

    /// Record a point-in-time event.
    func recordEvent(name: String, attributes: [String: String], spanContext: SpanContext?)

    /// Record a metric value.
    func recordMetric(name: String, value: Double, unit: String?, attributes: [String: String])
}

/// An opaque context for an active span.
public struct SpanContext: Sendable {
    public let id: String
    public let traceId: String
    public let startTime: Date

    public init(id: String = UUID().uuidString, traceId: String = UUID().uuidString, startTime: Date = Date()) {
        self.id = id
        self.traceId = traceId
        self.startTime = startTime
    }
}

/// The outcome of a span.
public enum SpanStatus: Sendable {
    case ok
    case error(String)
}

/// Protocol for redacting sensitive content before it enters telemetry.
public protocol ContentRedactor: Sendable {
    func redact(_ content: String) -> String
}

// MARK: - No-Op Implementation

/// Default observability engine that does nothing. Zero overhead when observability is not needed.
public struct NoOpObservabilityEngine: ObservabilityEngine {
    public init() {}

    public func startSpan(name: String, attributes: [String: String]) -> SpanContext {
        SpanContext()
    }

    public func endSpan(_ context: SpanContext, status: SpanStatus) {}

    public func recordEvent(name: String, attributes: [String: String], spanContext: SpanContext?) {}

    public func recordMetric(name: String, value: Double, unit: String?, attributes: [String: String]) {}
}
