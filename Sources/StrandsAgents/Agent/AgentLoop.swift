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
    let routingHints: RoutingHints

    init(
        router: any ModelRouter,
        toolRegistry: ToolRegistry,
        conversationManager: any ConversationManager,
        hookRegistry: HookRegistry,
        observability: any ObservabilityEngine,
        retryStrategy: RetryStrategy,
        maxCycles: Int,
        parallelToolExecution: Bool = true,
        agentState: AgentState? = nil,
        routingHints: RoutingHints = RoutingHints()
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
        self.routingHints = routingHints
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
            name: GenAISpanNames.invokeAgent,
            attributes: [
                GenAIAttributes.operationName: "invoke_agent",
                GenAIAttributes.eventStartTime: ISO8601DateFormatter().string(from: Date()),
            ]
        )
        defer { observability.endSpan(invocationSpan, status: .ok) }

        var lastModelLatencyMs: Int? = nil

        while cycleCount < maxCycles {
            cycleCount += 1

            let (aggregated, cycleSpan, modelLatencyMs, timeToFirstTokenMs, modelId) = try await runModelCycleWithMetrics(
                messages: messages,
                systemPrompt: systemPrompt,
                toolChoice: toolChoice,
                cycleCount: cycleCount,
                parentSpanId: invocationSpan.id,
                lastInferenceLatencyMs: lastModelLatencyMs
            )
            lastModelLatencyMs = modelLatencyMs

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
                    systemPrompt: systemPrompt, toolLatencies: &toolLatencies,
                    parentSpanId: cycleSpan.id
                )
            } else {
                var results: [ContentBlock] = []
                for toolUse in toolUses {
                    let toolCallStart = Date()
                    let result = try await executeSingleTool(
                        toolUse: toolUse, messages: messages, systemPrompt: systemPrompt,
                        parentSpanId: cycleSpan.id
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
            name: GenAISpanNames.invokeAgent,
            attributes: [
                GenAIAttributes.operationName: "invoke_agent",
                GenAIAttributes.eventStartTime: ISO8601DateFormatter().string(from: Date()),
            ]
        )
        defer { observability.endSpan(invocationSpan, status: .ok) }

        var lastModelLatencyMs: Int? = nil

        while cycleCount < maxCycles {
            cycleCount += 1

            let (aggregated, cycleSpan, modelLatencyMs, timeToFirstTokenMs, modelId) = try await runModelCycleStreamingWithMetrics(
                messages: messages,
                systemPrompt: systemPrompt,
                toolChoice: toolChoice,
                cycleCount: cycleCount,
                parentSpanId: invocationSpan.id,
                lastInferenceLatencyMs: lastModelLatencyMs,
                yield: yield
            )
            lastModelLatencyMs = modelLatencyMs

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
                    systemPrompt: systemPrompt, toolLatencies: &toolLatencies,
                    parentSpanId: cycleSpan.id
                )
            } else {
                var results: [ContentBlock] = []
                for toolUse in toolUses {
                    let start = Date()
                    let result = try await executeSingleTool(
                        toolUse: toolUse, messages: messages, systemPrompt: systemPrompt,
                        parentSpanId: cycleSpan.id
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
        messages: [Message], systemPrompt: String?, toolChoice: ToolChoice?, cycleCount: Int,
        parentSpanId: String, lastInferenceLatencyMs: Int? = nil
    ) async throws -> (StreamAggregator.AggregatedResult, SpanContext, Int, Int?, String?) {
        let cycleSpan = observability.startChildSpan(
            name: GenAISpanNames.eventLoopCycle,
            attributes: [
                GenAIAttributes.operationName: GenAISpanNames.eventLoopCycle,
                GenAIAttributes.eventLoopCycleId: "\(cycleCount)",
                GenAIAttributes.eventStartTime: ISO8601DateFormatter().string(from: Date()),
            ],
            parentId: parentSpanId
        )

        let toolSpecs = toolRegistry.count > 0 ? toolRegistry.toolSpecs : nil
        let normalizedMessages = MessageNormalizer.normalize(messages)
        let provider = try await resolveProvider(messages: normalizedMessages, toolSpecs: toolSpecs, systemPrompt: systemPrompt, lastInferenceLatencyMs: lastInferenceLatencyMs)

        try await hookRegistry.invoke(BeforeModelCallEvent(messages: normalizedMessages, toolSpecs: toolSpecs))

        var chatAttrs: [String: String] = [
            GenAIAttributes.operationName: "chat",
            GenAIAttributes.system: provider.genAISystem,
            GenAIAttributes.requestModel: provider.modelId ?? "unknown",
            GenAIAttributes.eventStartTime: ISO8601DateFormatter().string(from: Date()),
            // OTel GenAI 1.37+ input messages
            "gen_ai.input.messages": buildInputMessages(systemPrompt: systemPrompt, messages: normalizedMessages),
        ]
        chatAttrs.merge(provider.requestParams) { _, new in new }

        let modelSpan = observability.startChildSpan(
            name: GenAISpanNames.chat,
            attributes: chatAttrs,
            parentId: cycleSpan.id,
            spanKind: .client
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
            // OTel GenAI 1.37+ output messages
            let completionText = aggregated.message.textContent
            if !completionText.isEmpty {
                observability.setAttribute(modelSpan, key: "gen_ai.output.messages",
                    value: buildOutputMessages(text: completionText, finishReason: aggregated.stopReason.rawValue))
            }
            // gen_ai.choice event carries usage
            if let u = aggregated.usage {
                observability.recordEvent(name: GenAIEventNames.choice, attributes: [
                    "finish_reason": aggregated.stopReason.rawValue,
                    GenAIAttributes.usageInputTokens: "\(u.inputTokens)",
                    GenAIAttributes.usageOutputTokens: "\(u.outputTokens)",
                    GenAIAttributes.usageTotalTokens: "\(u.totalTokens)",
                ], spanContext: modelSpan)
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
        parentSpanId: String, lastInferenceLatencyMs: Int? = nil,
        yield: @escaping @Sendable (AgentStreamEvent) async -> Void
    ) async throws -> (StreamAggregator.AggregatedResult, SpanContext, Int, Int?, String?) {
        let cycleSpan = observability.startChildSpan(
            name: GenAISpanNames.eventLoopCycle,
            attributes: [
                GenAIAttributes.operationName: GenAISpanNames.eventLoopCycle,
                GenAIAttributes.eventLoopCycleId: "\(cycleCount)",
                GenAIAttributes.eventStartTime: ISO8601DateFormatter().string(from: Date()),
            ],
            parentId: parentSpanId
        )

        let toolSpecs = toolRegistry.count > 0 ? toolRegistry.toolSpecs : nil
        let normalizedMessages = MessageNormalizer.normalize(messages)
        let provider = try await resolveProvider(messages: normalizedMessages, toolSpecs: toolSpecs, systemPrompt: systemPrompt, lastInferenceLatencyMs: lastInferenceLatencyMs)

        try await hookRegistry.invoke(BeforeModelCallEvent(messages: normalizedMessages, toolSpecs: toolSpecs))

        var chatAttrs: [String: String] = [
            GenAIAttributes.operationName: "chat",
            GenAIAttributes.system: provider.genAISystem,
            GenAIAttributes.requestModel: provider.modelId ?? "unknown",
            GenAIAttributes.eventStartTime: ISO8601DateFormatter().string(from: Date()),
            // OTel GenAI 1.37+ input messages
            "gen_ai.input.messages": buildInputMessages(systemPrompt: systemPrompt, messages: normalizedMessages),
        ]
        chatAttrs.merge(provider.requestParams) { _, new in new }

        let modelSpan = observability.startChildSpan(
            name: GenAISpanNames.chat,
            attributes: chatAttrs,
            parentId: cycleSpan.id,
            spanKind: .client
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
            // gen_ai.completion as span attribute -- Python Strands SDK format
            let completionText = aggregated.message.textContent
            if !completionText.isEmpty {
                observability.setAttribute(modelSpan, key: "gen_ai.completion", value: jsonContent(completionText))
            }
            // gen_ai.choice event carries usage
            if let u = aggregated.usage {
                observability.recordEvent(name: GenAIEventNames.choice, attributes: [
                    "finish_reason": aggregated.stopReason.rawValue,
                    GenAIAttributes.usageInputTokens: "\(u.inputTokens)",
                    GenAIAttributes.usageOutputTokens: "\(u.outputTokens)",
                    GenAIAttributes.usageTotalTokens: "\(u.totalTokens)",
                ], spanContext: modelSpan)
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

    /// Serialize text as [{"text":"..."}] -- Python Strands SDK format for OTel message content.
    private func jsonContent(_ text: String) -> String {
        let obj: [[String: String]] = [["text": text]]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else {
            return "[{\"text\":\"\(text)\"}]"
        }
        return str
    }

    /// Build gen_ai.input.messages span attribute per OTel GenAI 1.37+ conventions:
    /// [{"role":"user","parts":[{"type":"text","content":"..."}]}, ...]
    private func buildInputMessages(systemPrompt: String?, messages: [Message]) -> String {
        var msgArray: [[String: Any]] = []
        if let sys = systemPrompt, !sys.isEmpty {
            msgArray.append(["role": "system", "parts": [["type": "text", "content": sys]]])
        }
        for msg in messages {
            let role = msg.role == .user ? "user" : "assistant"
            let text = msg.textContent
            if !text.isEmpty {
                msgArray.append(["role": role, "parts": [["type": "text", "content": text]]])
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: msgArray),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    /// Build gen_ai.output.messages span attribute per OTel GenAI 1.37+ conventions:
    /// [{"role":"assistant","parts":[{"type":"text","content":"..."}],"finish_reason":"..."}]
    private func buildOutputMessages(text: String, finishReason: String) -> String {
        let obj: [[String: Any]] = [[
            "role": "assistant",
            "parts": [["type": "text", "content": text]],
            "finish_reason": finishReason,
        ]]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    private func resolveProvider(
        messages: [Message],
        toolSpecs: [ToolSpec]?,
        systemPrompt: String?,
        lastInferenceLatencyMs: Int? = nil
    ) async throws -> any ModelProvider {
        let ctx = RoutingContext(
            messages: messages,
            toolSpecs: toolSpecs,
            systemPrompt: systemPrompt,
            hints: routingHints,
            deviceCapabilities: .current,
            lastInferenceLatencyMs: lastInferenceLatencyMs
        )
        return try await router.route(context: ctx)
    }

    private func executeTools(toolUses: [ToolUseBlock], messages: [Message], systemPrompt: String?, parentSpanId: String) async throws -> [ContentBlock] {
        if parallelToolExecution && toolUses.count > 1 {
            var latencies: [String: Int] = [:]
            return try await executeToolsParallelWithMetrics(
                toolUses: toolUses, messages: messages, systemPrompt: systemPrompt, toolLatencies: &latencies, parentSpanId: parentSpanId
            )
        }
        var results: [ContentBlock] = []
        for toolUse in toolUses {
            let result = try await executeSingleTool(toolUse: toolUse, messages: messages, systemPrompt: systemPrompt, parentSpanId: parentSpanId)
            results.append(.toolResult(result))
        }
        return results
    }

    private func executeToolsParallelWithMetrics(
        toolUses: [ToolUseBlock], messages: [Message], systemPrompt: String?,
        toolLatencies: inout [String: Int], parentSpanId: String
    ) async throws -> [ContentBlock] {
        let results = try await withThrowingTaskGroup(of: (Int, ToolResultBlock, String, Int).self) { group in
            for (index, toolUse) in toolUses.enumerated() {
                group.addTask {
                    let start = Date()
                    let result = try await self.executeSingleTool(
                        toolUse: toolUse, messages: messages, systemPrompt: systemPrompt,
                        parentSpanId: parentSpanId
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

    private func executeSingleTool(toolUse: ToolUseBlock, messages: [Message], systemPrompt: String?, parentSpanId: String) async throws -> ToolResultBlock {
        let toolSpan = observability.startChildSpan(
            name: "\(GenAISpanNames.executeTool) \(toolUse.name)",
            attributes: [
                GenAIAttributes.operationName: "execute_tool",
                GenAIAttributes.toolName: toolUse.name,
                GenAIAttributes.toolCallId: toolUse.toolUseId,
                GenAIAttributes.eventStartTime: ISO8601DateFormatter().string(from: Date()),
            ],
            parentId: parentSpanId
        )
        try await hookRegistry.invoke(BeforeToolCallEvent(toolUse: toolUse))

        // Record tool input as gen_ai event
        let toolInputStr: String = {
            if let v = toolUse.input.foundationValue,
               let d = try? JSONSerialization.data(withJSONObject: v),
               let s = String(data: d, encoding: .utf8) { return s }
            return "{}"
        }()
        observability.recordEvent(
            name: GenAIEventNames.toolMessage,
            attributes: ["role": "tool", "id": toolUse.toolUseId, "input": toolInputStr],
            spanContext: toolSpan
        )

        let result: ToolResultBlock
        if let tool = toolRegistry.tool(named: toolUse.name) {
            let context = ToolContext(toolUse: toolUse, messages: messages, systemPrompt: systemPrompt, agentState: agentState)
            do {
                result = try await tool.call(toolUse: toolUse, context: context)
                let outputStr = result.content.compactMap { (block: ToolResultContent) -> String? in
                    if case .text(let t) = block { return t }
                    return nil
                }.joined(separator: " ")
                observability.recordEvent(
                    name: GenAIEventNames.choice,
                    attributes: [GenAIAttributes.toolStatus: "success", "id": toolUse.toolUseId, "output": outputStr],
                    spanContext: toolSpan
                )
                observability.endSpan(toolSpan, status: .ok)
            } catch {
                result = ToolResultBlock(toolUseId: toolUse.toolUseId, status: .error, content: [.text("Error: \(error.localizedDescription)")])
                observability.recordEvent(
                    name: GenAIEventNames.choice,
                    attributes: [GenAIAttributes.toolStatus: "error", "id": toolUse.toolUseId],
                    spanContext: toolSpan
                )
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
        let cycleAttrs = [GenAIAttributes.eventLoopCycleId: "\(metrics.cycleNumber)"]
        observability.recordMetric(name: GenAIAttributes.serverRequestDuration, value: Double(metrics.modelLatencyMs), unit: "ms", attributes: cycleAttrs)
        if let ttft = metrics.timeToFirstTokenMs {
            observability.recordMetric(name: GenAIAttributes.serverTimeToFirstToken, value: Double(ttft), unit: "ms", attributes: cycleAttrs)
        }
        observability.recordMetric(name: GenAIAttributes.usageInputTokens, value: Double(metrics.usage.inputTokens), unit: "tokens", attributes: cycleAttrs)
        observability.recordMetric(name: GenAIAttributes.usageOutputTokens, value: Double(metrics.usage.outputTokens), unit: "tokens", attributes: cycleAttrs)
    }

    private func emitLoopMetrics(_ metrics: EventLoopMetrics) {
        observability.recordMetric(name: GenAIAttributes.serverRequestDuration, value: Double(metrics.totalLatencyMs), unit: "ms", attributes: [GenAIAttributes.operationName: "invoke_agent"])
        observability.recordMetric(name: GenAIAttributes.usageInputTokens, value: Double(metrics.totalUsage.inputTokens), unit: "tokens", attributes: [GenAIAttributes.operationName: "invoke_agent"])
        observability.recordMetric(name: GenAIAttributes.usageOutputTokens, value: Double(metrics.totalUsage.outputTokens), unit: "tokens", attributes: [GenAIAttributes.operationName: "invoke_agent"])
        observability.recordMetric(name: GenAIAttributes.usageTotalTokens, value: Double(metrics.totalUsage.totalTokens), unit: "tokens", attributes: [GenAIAttributes.operationName: "invoke_agent"])
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
