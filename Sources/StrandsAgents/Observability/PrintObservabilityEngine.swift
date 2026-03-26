import Foundation

/// An observability engine that prints events to standard output. Useful for debugging.
public struct PrintObservabilityEngine: ObservabilityEngine {
    public init() {}

    public func startSpan(name: String, attributes: [String: String], spanKind: SpanKind = .internal) -> SpanContext {
        let ctx = SpanContext()
        print("[SPAN START] \(name) kind=\(spanKind) id=\(ctx.id.prefix(8)) \(formatAttributes(attributes))")
        return ctx
    }

    public func startChildSpan(name: String, attributes: [String: String], parentId: String, spanKind: SpanKind = .internal) -> SpanContext {
        let ctx = SpanContext()
        print("[SPAN START] \(name) kind=\(spanKind) id=\(ctx.id.prefix(8)) parent=\(parentId.prefix(8)) \(formatAttributes(attributes))")
        return ctx
    }

    public func endSpan(_ context: SpanContext, status: SpanStatus) {
        let duration = Date().timeIntervalSince(context.startTime)
        let statusStr: String
        switch status {
        case .ok: statusStr = "OK"
        case .error(let msg): statusStr = "ERROR: \(msg)"
        }
        print("[SPAN END]   id=\(context.id.prefix(8)) status=\(statusStr) duration=\(String(format: "%.1fms", duration * 1000))")
    }

    public func recordEvent(name: String, attributes: [String: String], spanContext: SpanContext?) {
        let spanId = spanContext.map { String($0.id.prefix(8)) } ?? "none"
        print("[EVENT]      \(name) span=\(spanId) \(formatAttributes(attributes))")
    }

    public func recordMetric(name: String, value: Double, unit: String?, attributes: [String: String]) {
        let unitStr = unit.map { " \($0)" } ?? ""
        print("[METRIC]     \(name)=\(value)\(unitStr) \(formatAttributes(attributes))")
    }

    private func formatAttributes(_ attrs: [String: String]) -> String {
        guard !attrs.isEmpty else { return "" }
        return attrs.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
}
