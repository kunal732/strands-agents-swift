import Foundation

/// The core reasoning loop that drives the agent.
///
/// Repeatedly calls the model, executes tools, and iterates until the model
/// produces a final response or a stop condition is met. Collects detailed
/// per-cycle metrics for observability.
struct AgentLoop: Sendable {
    let router: any ModelRouter
    let toolRegistry: ToolRegistry
    let conversationManager: any ConversationManager
    let hookRegistry: HookRegistry
    let observability: any ObservabilityEngine
    let retryStrategy: RetryStrategy
    let maxCycles: Int
    let parallelToolExecution: Bool
    let agentState: AgentState?

    init(
        router: any ModelRouter,
        toolRegistry: ToolRegistry,
        conversationManager: any ConversationManager,
        hookRegistry: HookRegistry,
        observability: any ObservabilityEngine,
        retryStrategy: RetryStrategy,
        maxCycles: Int,
        parallelToolExecution: Bool = true,
        agentState: AgentState? = nil
    ) {
        self.router = router
        self.toolRegistry = toolRegistry
        self.conversationManager = conversationManager
        self.hookRegistry = hookRegistry
        self.observability = observability
        self.retryStrategy = retryStrategy
        self.maxCycles = maxCycles
        self.parallelToolExecution = parallelToolExecution
        self.agentState = agentState
    }

    /// Execute the agent loop, returning the final result with detailed metrics.
    func run(
        messages: inout [Message],
        systemPrompt: String?,
        toolChoice: ToolChoice?
    ) async throws -> AgentResult {
        var totalUsage = Usage()
        var cycleCount = 0
        var allCycleMetrics: [CycleMetrics] = []
        let invocationStart = Date()

        let invocationSpan = observability.startSpan(
            name: "strands.agent.invocation",
            attributes: ["message_count": "\(messages.count)"]
        )
        defer { observability.endSpan(invocationSpan, status: .ok) }

        while cycleCount < maxCycles {
            cycleCount += 1
            let cycleStart = Date()

            let (aggregated, cycleSpan, modelLatencyMs, timeToFirstTokenMs, modelId) = try await runModelCycleWithMetrics(
                messages: messages,
                systemPrompt: systemPrompt,
                toolChoice: toolChoice,
                cycleCount: cycleCount
            )

            accumulateUsage(&totalUsage, from: aggregated.usage)

            // Handle max_tokens: recover by appending partial response and continuing
            if aggregated.stopReason == .maxTokens {
                messages.append(aggregated.message)
                observability.endSpan(cycleSpan, status: .ok)

                let cycleMetric = CycleMetrics(
                    cycleNumber: cycleCount,
                    usage: aggregated.usage ?? Usage(),
                    modelLatencyMs: modelLatencyMs,
                    timeToFirstTokenMs: timeToFirstTokenMs,
                    stopReason: .maxTokens,
                    modelId: modelId
                )
                allCycleMetrics.append(cycleMetric)
                emitCycleMetrics(cycleMetric)

                // Continue the loop -- model will see the partial response and continue
                continue
            }

            if aggregated.stopReason != StopReason.toolUse {
                messages.append(aggregated.message)
                observability.endSpan(cycleSpan, status: .ok)

                let cycleMetric = CycleMetrics(
                    cycleNumber: cycleCount,
                    usage: aggregated.usage ?? Usage(),
                    modelLatencyMs: modelLatencyMs,
                    timeToFirstTokenMs: timeToFirstTokenMs,
                    stopReason: aggregated.stopReason,
                    modelId: modelId
                )
                allCycleMetrics.append(cycleMetric)
                emitCycleMetrics(cycleMetric)

                let loopMetrics = buildLoopMetrics(
                    cycles: allCycleMetrics, totalUsage: totalUsage, since: invocationStart
                )

                // Emit metrics event
                try? await hookRegistry.invoke(MetricsEvent(metrics: loopMetrics))
                emitLoopMetrics(loopMetrics)

                return AgentResult(
                    stopReason: aggregated.stopReason,
                    message: aggregated.message,
                    usage: totalUsage,
                    cycleCount: cycleCount,
                    metrics: loopMetrics
                )
            }

            // Execute tools and collect per-tool latencies
            let toolUses = aggregated.message.toolUses
            let toolStart = Date()
            let toolResultContents: [ContentBlock]
            var toolLatencies: [String: Int] = [:]

            if parallelToolExecution && toolUses.count > 1 {
                toolResultContents = try await executeToolsParallelWithMetrics(
                    toolUses: toolUses, messages: messages,
                    systemPrompt: systemPrompt, toolLatencies: &toolLatencies
                )
            } else {
                var results: [ContentBlock] = []
                for toolUse in toolUses {
                    let toolCallStart = Date()
                    let result = try await executeSingleTool(
                        toolUse: toolUse, messages: messages, systemPrompt: systemPrompt
                    )
                    results.append(.toolResult(result))
                    toolLatencies[toolUse.name] = Int(Date().timeIntervalSince(toolCallStart) * 1000)
                }
                toolResultContents = results
            }

            messages.append(aggregated.message)
            messages.append(Message(role: .user, content: toolResultContents))
            await conversationManager.applyManagement(messages: &messages)
            observability.endSpan(cycleSpan, status: .ok)

            let cycleMetric = CycleMetrics(
                cycleNumber: cycleCount,
                usage: aggregated.usage ?? Usage(),
                modelLatencyMs: modelLatencyMs,
                timeToFirstTokenMs: timeToFirstTokenMs,
                toolsExecuted: toolUses.count,
                toolLatencies: toolLatencies,
                stopReason: .toolUse,
                modelId: modelId
            )
            allCycleMetrics.append(cycleMetric)
            emitCycleMetrics(cycleMetric)
        }

        let lastAssistant = messages.last { $0.role == .assistant }
            ?? Message.assistant("[Agent reached maximum cycle limit]")

        let loopMetrics = buildLoopMetrics(
            cycles: allCycleMetrics, totalUsage: totalUsage, since: invocationStart
        )
        try? await hookRegistry.invoke(MetricsEvent(metrics: loopMetrics))
        emitLoopMetrics(loopMetrics)

        return AgentResult(
            stopReason: .endTurn,
            message: lastAssistant,
            usage: totalUsage,
            cycleCount: cycleCount,
            metrics: loopMetrics
        )
    }

    /// Execute the agent loop and yield streaming events with metrics.
    func runStreaming(
        messages: inout [Message],
        systemPrompt: String?,
        toolChoice: ToolChoice?,
        yield: @escaping @Sendable (AgentStreamEvent) async -> Void
    ) async throws -> AgentResult {
        var totalUsage = Usage()
        var cycleCount = 0
        var allCycleMetrics: [CycleMetrics] = []
        let invocationStart = Date()

        let invocationSpan = observability.startSpan(
            name: "strands.agent.invocation",
            attributes: ["message_count": "\(messages.count)"]
        )
        defer { observability.endSpan(invocationSpan, status: .ok) }

        while cycleCount < maxCycles {
            cycleCount += 1

            let (aggregated, cycleSpan, modelLatencyMs, timeToFirstTokenMs, modelId) = try await runModelCycleStreamingWithMetrics(
                messages: messages,
                systemPrompt: systemPrompt,
                toolChoice: toolChoice,
                cycleCount: cycleCount,
                yield: yield
            )

            accumulateUsage(&totalUsage, from: aggregated.usage)

            await yield(.modelMessage(aggregated.message))

            // Handle max_tokens recovery
            if aggregated.stopReason == .maxTokens {
                messages.append(aggregated.message)
                observability.endSpan(cycleSpan, status: .ok)
                allCycleMetrics.append(CycleMetrics(
                    cycleNumber: cycleCount, usage: aggregated.usage ?? Usage(),
                    modelLatencyMs: modelLatencyMs, timeToFirstTokenMs: timeToFirstTokenMs,
                    stopReason: .maxTokens, modelId: modelId
                ))
                continue
            }

            if aggregated.stopReason != StopReason.toolUse {
                messages.append(aggregated.message)
                observability.endSpan(cycleSpan, status: .ok)

                allCycleMetrics.append(CycleMetrics(
                    cycleNumber: cycleCount, usage: aggregated.usage ?? Usage(),
                    modelLatencyMs: modelLatencyMs, timeToFirstTokenMs: timeToFirstTokenMs,
                    stopReason: aggregated.stopReason, modelId: modelId
                ))

                let loopMetrics = buildLoopMetrics(
                    cycles: allCycleMetrics, totalUsage: totalUsage, since: invocationStart
                )
                try? await hookRegistry.invoke(MetricsEvent(metrics: loopMetrics))
                emitLoopMetrics(loopMetrics)

                let result = AgentResult(
                    stopReason: aggregated.stopReason,
                    message: aggregated.message,
                    usage: totalUsage,
                    cycleCount: cycleCount,
                    metrics: loopMetrics
                )
                await yield(.result(result))
                return result
            }

            // Execute tools
            let toolUses = aggregated.message.toolUses
            var toolLatencies: [String: Int] = [:]
            let toolResultContents: [ContentBlock]

            if parallelToolExecution && toolUses.count > 1 {
                toolResultContents = try await executeToolsParallelWithMetrics(
                    toolUses: toolUses, messages: messages,
                    systemPrompt: systemPrompt, toolLatencies: &toolLatencies
                )
            } else {
                var results: [ContentBlock] = []
                for toolUse in toolUses {
                    let start = Date()
                    let result = try await executeSingleTool(
                        toolUse: toolUse, messages: messages, systemPrompt: systemPrompt
                    )
                    results.append(.toolResult(result))
                    toolLatencies[toolUse.name] = Int(Date().timeIntervalSince(start) * 1000)
                }
                toolResultContents = results
            }

            for block in toolResultContents {
                if case .toolResult(let r) = block { await yield(.toolResult(r)) }
            }

            messages.append(aggregated.message)
            messages.append(Message(role: .user, content: toolResultContents))
            await conversationManager.applyManagement(messages: &messages)
            observability.endSpan(cycleSpan, status: .ok)

            allCycleMetrics.append(CycleMetrics(
                cycleNumber: cycleCount, usage: aggregated.usage ?? Usage(),
                modelLatencyMs: modelLatencyMs, timeToFirstTokenMs: timeToFirstTokenMs,
                toolsExecuted: toolUses.count, toolLatencies: toolLatencies,
                stopReason: .toolUse, modelId: modelId
            ))
        }

        let lastAssistant = messages.last { $0.role == .assistant }
            ?? Message.assistant("[Agent reached maximum cycle limit]")
        let loopMetrics = buildLoopMetrics(
            cycles: allCycleMetrics, totalUsage: totalUsage, since: invocationStart
        )
        try? await hookRegistry.invoke(MetricsEvent(metrics: loopMetrics))
        emitLoopMetrics(loopMetrics)

        let result = AgentResult(
            stopReason: .endTurn, message: lastAssistant,
            usage: totalUsage, cycleCount: cycleCount, metrics: loopMetrics
        )
        await yield(.result(result))
        return result
    }

    // MARK: - Model Cycle with Metrics

    private func runModelCycleWithMetrics(
        messages: [Message], systemPrompt: String?, toolChoice: ToolChoice?, cycleCount: Int
    ) async throws -> (StreamAggregator.AggregatedResult, SpanContext, Int, Int?, String?) {
        let cycleSpan = observability.startSpan(
            name: "strands.agent.loop.cycle", attributes: ["cycle": "\(cycleCount)"]
        )

        let toolSpecs = toolRegistry.count > 0 ? toolRegistry.toolSpecs : nil
        let normalizedMessages = MessageNormalizer.normalize(messages)
        let provider = try await resolveProvider(messages: normalizedMessages, toolSpecs: toolSpecs, systemPrompt: systemPrompt)

        try await hookRegistry.invoke(BeforeModelCallEvent(messages: normalizedMessages, toolSpecs: toolSpecs))

        let modelSpan = observability.startSpan(
            name: "strands.model.invoke",
            attributes: ["model_id": provider.modelId ?? "unknown", "cycle": "\(cycleCount)"]
        )

        let modelStart = Date()
        let ttftTracker = TTFTTracker()

        let aggregated: StreamAggregator.AggregatedResult
        do {
            let stream = provider.stream(
                messages: normalizedMessages, toolSpecs: toolSpecs,
                systemPrompt: systemPrompt, toolChoice: toolChoice
            )
            aggregated = try await retryStrategy.execute {
                try await StreamAggregator().aggregate(
                    stream: stream,
                    onTextDelta: { _ in ttftTracker.mark() }
                )
            }
            observability.endSpan(modelSpan, status: .ok)
        } catch {
            observability.endSpan(modelSpan, status: .error(error.localizedDescription))
            observability.endSpan(cycleSpan, status: .error(error.localizedDescription))
            throw error
        }

        let modelLatencyMs = Int(Date().timeIntervalSince(modelStart) * 1000)
        let ttftMs = ttftTracker.time.map { Int($0.timeIntervalSince(modelStart) * 1000) }

        try await hookRegistry.invoke(AfterModelCallEvent(
            message: aggregated.message, stopReason: aggregated.stopReason, usage: aggregated.usage
        ))

        return (aggregated, cycleSpan, modelLatencyMs, ttftMs, provider.modelId)
    }

    private func runModelCycleStreamingWithMetrics(
        messages: [Message], systemPrompt: String?, toolChoice: ToolChoice?, cycleCount: Int,
        yield: @escaping @Sendable (AgentStreamEvent) async -> Void
    ) async throws -> (StreamAggregator.AggregatedResult, SpanContext, Int, Int?, String?) {
        let cycleSpan = observability.startSpan(
            name: "strands.agent.loop.cycle", attributes: ["cycle": "\(cycleCount)"]
        )

        let toolSpecs = toolRegistry.count > 0 ? toolRegistry.toolSpecs : nil
        let normalizedMessages = MessageNormalizer.normalize(messages)
        let provider = try await resolveProvider(messages: normalizedMessages, toolSpecs: toolSpecs, systemPrompt: systemPrompt)

        try await hookRegistry.invoke(BeforeModelCallEvent(messages: normalizedMessages, toolSpecs: toolSpecs))

        let modelSpan = observability.startSpan(
            name: "strands.model.invoke",
            attributes: ["model_id": provider.modelId ?? "unknown", "cycle": "\(cycleCount)"]
        )

        let modelStart = Date()
        let ttftTracker = TTFTTracker()

        let aggregated: StreamAggregator.AggregatedResult
        do {
            let stream = provider.stream(
                messages: normalizedMessages, toolSpecs: toolSpecs,
                systemPrompt: systemPrompt, toolChoice: toolChoice
            )
            aggregated = try await retryStrategy.execute {
                try await StreamAggregator().aggregate(
                    stream: stream,
                    onContentBlock: { block in await yield(.contentBlock(block)) },
                    onTextDelta: { text in
                        ttftTracker.mark()
                        await yield(.textDelta(text))
                    }
                )
            }
            observability.endSpan(modelSpan, status: .ok)
        } catch {
            observability.endSpan(modelSpan, status: .error(error.localizedDescription))
            observability.endSpan(cycleSpan, status: .error(error.localizedDescription))
            throw error
        }

        let modelLatencyMs = Int(Date().timeIntervalSince(modelStart) * 1000)
        let ttftMs = ttftTracker.time.map { Int($0.timeIntervalSince(modelStart) * 1000) }

        try await hookRegistry.invoke(AfterModelCallEvent(
            message: aggregated.message, stopReason: aggregated.stopReason, usage: aggregated.usage
        ))

        return (aggregated, cycleSpan, modelLatencyMs, ttftMs, provider.modelId)
    }

    // MARK: - Helpers

    private func resolveProvider(messages: [Message], toolSpecs: [ToolSpec]?, systemPrompt: String?) async throws -> any ModelProvider {
        let ctx = RoutingContext(messages: messages, toolSpecs: toolSpecs, systemPrompt: systemPrompt)
        return try await router.route(context: ctx)
    }

    private func executeTools(toolUses: [ToolUseBlock], messages: [Message], systemPrompt: String?) async throws -> [ContentBlock] {
        if parallelToolExecution && toolUses.count > 1 {
            var latencies: [String: Int] = [:]
            return try await executeToolsParallelWithMetrics(
                toolUses: toolUses, messages: messages, systemPrompt: systemPrompt, toolLatencies: &latencies
            )
        }
        var results: [ContentBlock] = []
        for toolUse in toolUses {
            let result = try await executeSingleTool(toolUse: toolUse, messages: messages, systemPrompt: systemPrompt)
            results.append(.toolResult(result))
        }
        return results
    }

    private func executeToolsParallelWithMetrics(
        toolUses: [ToolUseBlock], messages: [Message], systemPrompt: String?,
        toolLatencies: inout [String: Int]
    ) async throws -> [ContentBlock] {
        let results = try await withThrowingTaskGroup(of: (Int, ToolResultBlock, String, Int).self) { group in
            for (index, toolUse) in toolUses.enumerated() {
                group.addTask {
                    let start = Date()
                    let result = try await self.executeSingleTool(
                        toolUse: toolUse, messages: messages, systemPrompt: systemPrompt
                    )
                    let latency = Int(Date().timeIntervalSince(start) * 1000)
                    return (index, result, toolUse.name, latency)
                }
            }
            var indexed: [(Int, ToolResultBlock, String, Int)] = []
            for try await tuple in group { indexed.append(tuple) }
            return indexed
        }

        for (_, _, name, latency) in results {
            toolLatencies[name] = latency
        }

        return results.sorted { $0.0 < $1.0 }.map { .toolResult($0.1) }
    }

    private func executeSingleTool(toolUse: ToolUseBlock, messages: [Message], systemPrompt: String?) async throws -> ToolResultBlock {
        let toolSpan = observability.startSpan(name: "strands.tool.invoke", attributes: ["tool_name": toolUse.name])
        try await hookRegistry.invoke(BeforeToolCallEvent(toolUse: toolUse))

        let result: ToolResultBlock
        if let tool = toolRegistry.tool(named: toolUse.name) {
            let context = ToolContext(toolUse: toolUse, messages: messages, systemPrompt: systemPrompt, agentState: agentState)
            do {
                result = try await tool.call(toolUse: toolUse, context: context)
                observability.endSpan(toolSpan, status: .ok)
            } catch {
                result = ToolResultBlock(toolUseId: toolUse.toolUseId, status: .error, content: [.text("Error: \(error.localizedDescription)")])
                observability.endSpan(toolSpan, status: .error(error.localizedDescription))
            }
        } else {
            result = ToolResultBlock(toolUseId: toolUse.toolUseId, status: .error, content: [.text("Tool not found: \(toolUse.name)")])
            observability.endSpan(toolSpan, status: .error("Tool not found"))
        }

        try await hookRegistry.invoke(AfterToolCallEvent(toolUse: toolUse, result: result))
        return result
    }

    private func accumulateUsage(_ total: inout Usage, from usage: Usage?) {
        guard let usage else { return }
        total.inputTokens += usage.inputTokens
        total.outputTokens += usage.outputTokens
        total.totalTokens += usage.totalTokens
    }

    private func buildLoopMetrics(cycles: [CycleMetrics], totalUsage: Usage, since start: Date) -> EventLoopMetrics {
        EventLoopMetrics(
            cycles: cycles,
            totalUsage: totalUsage,
            totalLatencyMs: Int(Date().timeIntervalSince(start) * 1000)
        )
    }

    private func emitCycleMetrics(_ metrics: CycleMetrics) {
        observability.recordMetric(name: "strands.cycle.model_latency_ms", value: Double(metrics.modelLatencyMs), unit: "ms", attributes: ["cycle": "\(metrics.cycleNumber)"])
        if let ttft = metrics.timeToFirstTokenMs {
            observability.recordMetric(name: "strands.cycle.ttft_ms", value: Double(ttft), unit: "ms", attributes: ["cycle": "\(metrics.cycleNumber)"])
        }
        observability.recordMetric(name: "strands.cycle.input_tokens", value: Double(metrics.usage.inputTokens), unit: "tokens", attributes: ["cycle": "\(metrics.cycleNumber)"])
        observability.recordMetric(name: "strands.cycle.output_tokens", value: Double(metrics.usage.outputTokens), unit: "tokens", attributes: ["cycle": "\(metrics.cycleNumber)"])
    }

    private func emitLoopMetrics(_ metrics: EventLoopMetrics) {
        observability.recordMetric(name: "strands.invocation.total_latency_ms", value: Double(metrics.totalLatencyMs), unit: "ms", attributes: [:])
        observability.recordMetric(name: "strands.invocation.total_input_tokens", value: Double(metrics.totalUsage.inputTokens), unit: "tokens", attributes: [:])
        observability.recordMetric(name: "strands.invocation.total_output_tokens", value: Double(metrics.totalUsage.outputTokens), unit: "tokens", attributes: [:])
        observability.recordMetric(name: "strands.invocation.cycle_count", value: Double(metrics.cycleCount), unit: "count", attributes: [:])
        observability.recordMetric(name: "strands.invocation.output_tokens_per_second", value: metrics.outputTokensPerSecond, unit: "tokens/s", attributes: [:])
    }
}

// MARK: - Time to First Token Tracker

/// Thread-safe tracker for time-to-first-token measurement.
private final class TTFTTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _time: Date?

    var time: Date? { lock.withLock { _time } }

    func mark() {
        lock.withLock {
            if _time == nil { _time = Date() }
        }
    }
}
