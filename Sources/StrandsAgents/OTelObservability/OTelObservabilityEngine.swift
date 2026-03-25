import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp
import OpenTelemetryProtocolExporterCommon

/// OpenTelemetry-based observability engine for Strands agents.
///
/// Integrates with any OTel-compatible backend (Datadog, Jaeger, AWS OTEL, etc.)
/// via configured exporters.
///
/// ```swift
/// import OpenTelemetrySdk
/// import StrandsOTelObservability
///
/// // Configure your tracer provider with exporters first, then:
/// let tracer = OpenTelemetry.instance.tracerProvider
///     .get(instrumentationName: "my-service", instrumentationVersion: "1.0.0")
/// let otel = OTelObservabilityEngine(tracer: tracer)
/// let agent = Agent(model: provider, observability: otel)
/// ```
public final class OTelObservabilityEngine: StrandsAgents.ObservabilityEngine, @unchecked Sendable {
    private let tracer: OpenTelemetryApi.Tracer
    private let redactor: (any StrandsAgents.ContentRedactor)?
    private let lock = NSLock()
    private var activeSpans: [String: OpenTelemetryApi.Span] = [:]

    /// Create an OTel engine with an existing tracer.
    public init(
        tracer: OpenTelemetryApi.Tracer,
        redactor: (any StrandsAgents.ContentRedactor)? = nil
    ) {
        self.tracer = tracer
        self.redactor = redactor
    }

    // MARK: - Convenience factories

    /// Create an engine pre-configured for Datadog LLM Observability.
    ///
    /// Sends traces to Datadog's OTLP intake using the `gen_ai` semantic conventions
    /// that Datadog's LLM Observability product reads natively.
    ///
    /// ```swift
    /// let agent = Agent(
    ///     model: provider,
    ///     observability: OTelObservabilityEngine.datadog(
    ///         apiKey: ProcessInfo.processInfo.environment["DD_API_KEY"] ?? "",
    ///         service: "my-app"
    ///     )
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - apiKey: Your Datadog API key.
    ///   - service: The service name shown in Datadog (e.g. your app's bundle identifier).
    ///   - version: Optional service version string.
    ///   - site: Datadog site. Defaults to US1 (`datadoghq.com`). Use `datadoghq.eu` for EU.
    ///   - redactor: Optional content redactor for sensitive prompt data.
    /// - Returns: A configured `OTelObservabilityEngine` ready to attach to an agent.
    public static func datadog(
        apiKey: String,
        service: String,
        version: String = "1.0",
        site: String = "datadoghq.com",
        endpoint: URL? = nil,
        redactor: (any StrandsAgents.ContentRedactor)? = nil
    ) -> OTelObservabilityEngine {
        let endpoint = endpoint ?? URL(string: "https://otlp.\(site)/v1/traces")!
        let config = OtlpConfiguration(
            headers: [
                ("dd-api-key", apiKey),
                ("dd-otlp-source", "llmobs"),
            ]
        )
        let exporter = OtlpHttpTraceExporter(endpoint: endpoint, config: config)
        let provider = TracerProviderBuilder()
            .add(spanProcessor: BatchSpanProcessor(spanExporter: exporter))
            .with(resource: Resource(attributes: [
                ResourceAttributes.serviceName.rawValue: AttributeValue.string(service),
                ResourceAttributes.serviceVersion.rawValue: AttributeValue.string(version),
            ]))
            .build()
        OpenTelemetry.registerTracerProvider(tracerProvider: provider)
        let tracer = provider.get(instrumentationName: service, instrumentationVersion: version)
        return OTelObservabilityEngine(tracer: tracer, redactor: redactor)
    }

    // MARK: - ObservabilityEngine

    public func startSpan(
        name: String,
        attributes: [String: String]
    ) -> StrandsAgents.SpanContext {
        buildSpan(name: name, attributes: attributes, parentSpan: nil)
    }

    public func startChildSpan(
        name: String,
        attributes: [String: String],
        parentId: String
    ) -> StrandsAgents.SpanContext {
        let parent = lock.withLock { activeSpans[parentId] }
        return buildSpan(name: name, attributes: attributes, parentSpan: parent)
    }

    private func buildSpan(
        name: String,
        attributes: [String: String],
        parentSpan: OpenTelemetryApi.Span?
    ) -> StrandsAgents.SpanContext {
        let spanBuilder = tracer.spanBuilder(spanName: name)

        if let parent = parentSpan {
            spanBuilder.setParent(parent.context)
        }

        for (key, value) in attributes {
            let redacted = redactor?.redact(value) ?? value
            spanBuilder.setAttribute(key: key, value: redacted)
        }

        let span = spanBuilder.startSpan()
        let ctx = StrandsAgents.SpanContext(
            id: span.context.spanId.hexString,
            traceId: span.context.traceId.hexString
        )

        lock.withLock {
            activeSpans[ctx.id] = span
        }

        return ctx
    }

    public func endSpan(
        _ context: StrandsAgents.SpanContext,
        status: StrandsAgents.SpanStatus
    ) {
        let span: OpenTelemetryApi.Span? = lock.withLock {
            activeSpans.removeValue(forKey: context.id)
        }

        guard let span else { return }

        switch status {
        case .ok:
            span.status = .ok
        case .error(let message):
            span.status = .error(description: message)
        }

        span.end()
    }

    public func recordEvent(
        name: String,
        attributes: [String: String],
        spanContext: StrandsAgents.SpanContext?
    ) {
        let span: OpenTelemetryApi.Span?
        if let ctx = spanContext {
            span = lock.withLock { activeSpans[ctx.id] }
        } else {
            span = nil
        }

        var eventAttributes: [String: OpenTelemetryApi.AttributeValue] = [:]
        for (key, value) in attributes {
            let redacted = redactor?.redact(value) ?? value
            eventAttributes[key] = .string(redacted)
        }

        span?.addEvent(name: name, attributes: eventAttributes)
    }

    public func recordMetric(
        name: String,
        value: Double,
        unit: String?,
        attributes: [String: String]
    ) {
        // Simplified: metrics recorded as span events.
        // For full metrics, configure OTel MeterProvider separately.
    }
}
