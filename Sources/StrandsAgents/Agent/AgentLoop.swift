import Foundation

/// The core reasoning loop that drives the agent.
///
/// Repeatedly calls the model, executes tools, and iterates until the model
/// produces a final response or a stop condition is met.
struct AgentLoop: Sendable {
    let router: any ModelRouter
    let toolRegistry: ToolRegistry
    let conversationManager: any ConversationManager
    let hookRegistry: HookRegistry
    let observability: any ObservabilityEngine
    let retryStrategy: RetryStrategy
    let maxCycles: Int

    /// Execute the agent loop, returning the final result.
    func run(
        messages: inout [Message],
        systemPrompt: String?,
        toolChoice: ToolChoice?
    ) async throws -> AgentResult {
        var totalUsage = Usage()
        var cycleCount = 0

        let invocationSpan = observability.startSpan(
            name: "strands.agent.invocation",
            attributes: ["message_count": "\(messages.count)"]
        )
        defer { observability.endSpan(invocationSpan, status: .ok) }

        while cycleCount < maxCycles {
            cycleCount += 1

            let (aggregated, cycleSpan) = try await runModelCycle(
                messages: messages,
                systemPrompt: systemPrompt,
                toolChoice: toolChoice,
                cycleCount: cycleCount
            )

            accumulateUsage(&totalUsage, from: aggregated.usage)

            if aggregated.stopReason != StopReason.toolUse {
                messages.append(aggregated.message)
                observability.endSpan(cycleSpan, status: .ok)
                return AgentResult(
                    stopReason: aggregated.stopReason,
                    message: aggregated.message,
                    usage: totalUsage,
                    cycleCount: cycleCount
                )
            }

            // Execute tools and append messages
            let toolResultContents = try await executeTools(
                toolUses: aggregated.message.toolUses,
                messages: messages,
                systemPrompt: systemPrompt
            )

            messages.append(aggregated.message)
            messages.append(Message(role: .user, content: toolResultContents))
            await conversationManager.applyManagement(messages: &messages)
            observability.endSpan(cycleSpan, status: .ok)
        }

        let lastAssistant = messages.last { $0.role == .assistant }
            ?? Message.assistant("[Agent reached maximum cycle limit]")
        return AgentResult(
            stopReason: .endTurn,
            message: lastAssistant,
            usage: totalUsage,
            cycleCount: cycleCount
        )
    }

    /// Execute the agent loop and yield streaming events (text deltas, content blocks, tool results).
    func runStreaming(
        messages: inout [Message],
        systemPrompt: String?,
        toolChoice: ToolChoice?,
        yield: @escaping @Sendable (AgentStreamEvent) async -> Void
    ) async throws -> AgentResult {
        var totalUsage = Usage()
        var cycleCount = 0

        let invocationSpan = observability.startSpan(
            name: "strands.agent.invocation",
            attributes: ["message_count": "\(messages.count)"]
        )
        defer { observability.endSpan(invocationSpan, status: .ok) }

        while cycleCount < maxCycles {
            cycleCount += 1

            let (aggregated, cycleSpan) = try await runModelCycleStreaming(
                messages: messages,
                systemPrompt: systemPrompt,
                toolChoice: toolChoice,
                cycleCount: cycleCount,
                yield: yield
            )

            accumulateUsage(&totalUsage, from: aggregated.usage)

            await yield(.modelMessage(aggregated.message))

            if aggregated.stopReason != StopReason.toolUse {
                messages.append(aggregated.message)
                observability.endSpan(cycleSpan, status: .ok)
                let result = AgentResult(
                    stopReason: aggregated.stopReason,
                    message: aggregated.message,
                    usage: totalUsage,
                    cycleCount: cycleCount
                )
                await yield(.result(result))
                return result
            }

            // Execute tools
            let toolUses = aggregated.message.toolUses
            var toolResultContents: [ContentBlock] = []

            for toolUse in toolUses {
                let result = try await executeSingleTool(
                    toolUse: toolUse,
                    messages: messages,
                    systemPrompt: systemPrompt
                )
                toolResultContents.append(.toolResult(result))
                await yield(.toolResult(result))
            }

            messages.append(aggregated.message)
            messages.append(Message(role: .user, content: toolResultContents))
            await conversationManager.applyManagement(messages: &messages)
            observability.endSpan(cycleSpan, status: .ok)
        }

        let lastAssistant = messages.last { $0.role == .assistant }
            ?? Message.assistant("[Agent reached maximum cycle limit]")
        let result = AgentResult(
            stopReason: .endTurn,
            message: lastAssistant,
            usage: totalUsage,
            cycleCount: cycleCount
        )
        await yield(.result(result))
        return result
    }

    // MARK: - Private Helpers

    private func runModelCycle(
        messages: [Message],
        systemPrompt: String?,
        toolChoice: ToolChoice?,
        cycleCount: Int
    ) async throws -> (StreamAggregator.AggregatedResult, SpanContext) {
        let cycleSpan = observability.startSpan(
            name: "strands.agent.loop.cycle",
            attributes: ["cycle": "\(cycleCount)"]
        )

        let toolSpecs = toolRegistry.count > 0 ? toolRegistry.toolSpecs : nil
        let provider = try await resolveProvider(messages: messages, toolSpecs: toolSpecs, systemPrompt: systemPrompt)

        try await hookRegistry.invoke(BeforeModelCallEvent(messages: messages, toolSpecs: toolSpecs))

        let modelSpan = observability.startSpan(
            name: "strands.model.invoke",
            attributes: ["model_id": provider.modelId ?? "unknown", "cycle": "\(cycleCount)"]
        )

        let aggregated: StreamAggregator.AggregatedResult
        do {
            let stream = provider.stream(
                messages: messages, toolSpecs: toolSpecs,
                systemPrompt: systemPrompt, toolChoice: toolChoice
            )
            aggregated = try await retryStrategy.execute {
                try await StreamAggregator().aggregate(stream: stream)
            }
            observability.endSpan(modelSpan, status: .ok)
        } catch {
            observability.endSpan(modelSpan, status: .error(error.localizedDescription))
            observability.endSpan(cycleSpan, status: .error(error.localizedDescription))
            throw error
        }

        try await hookRegistry.invoke(AfterModelCallEvent(
            message: aggregated.message, stopReason: aggregated.stopReason, usage: aggregated.usage
        ))

        return (aggregated, cycleSpan)
    }

    private func runModelCycleStreaming(
        messages: [Message],
        systemPrompt: String?,
        toolChoice: ToolChoice?,
        cycleCount: Int,
        yield: @escaping @Sendable (AgentStreamEvent) async -> Void
    ) async throws -> (StreamAggregator.AggregatedResult, SpanContext) {
        let cycleSpan = observability.startSpan(
            name: "strands.agent.loop.cycle",
            attributes: ["cycle": "\(cycleCount)"]
        )

        let toolSpecs = toolRegistry.count > 0 ? toolRegistry.toolSpecs : nil
        let provider = try await resolveProvider(messages: messages, toolSpecs: toolSpecs, systemPrompt: systemPrompt)

        try await hookRegistry.invoke(BeforeModelCallEvent(messages: messages, toolSpecs: toolSpecs))

        let modelSpan = observability.startSpan(
            name: "strands.model.invoke",
            attributes: ["model_id": provider.modelId ?? "unknown", "cycle": "\(cycleCount)"]
        )

        let aggregated: StreamAggregator.AggregatedResult
        do {
            let stream = provider.stream(
                messages: messages, toolSpecs: toolSpecs,
                systemPrompt: systemPrompt, toolChoice: toolChoice
            )
            aggregated = try await retryStrategy.execute {
                try await StreamAggregator().aggregate(
                    stream: stream,
                    onContentBlock: { block in await yield(.contentBlock(block)) },
                    onTextDelta: { text in await yield(.textDelta(text)) }
                )
            }
            observability.endSpan(modelSpan, status: .ok)
        } catch {
            observability.endSpan(modelSpan, status: .error(error.localizedDescription))
            observability.endSpan(cycleSpan, status: .error(error.localizedDescription))
            throw error
        }

        try await hookRegistry.invoke(AfterModelCallEvent(
            message: aggregated.message, stopReason: aggregated.stopReason, usage: aggregated.usage
        ))

        return (aggregated, cycleSpan)
    }

    private func resolveProvider(
        messages: [Message],
        toolSpecs: [ToolSpec]?,
        systemPrompt: String?
    ) async throws -> any ModelProvider {
        let routingContext = RoutingContext(
            messages: messages, toolSpecs: toolSpecs, systemPrompt: systemPrompt
        )
        return try await router.route(context: routingContext)
    }

    private func executeTools(
        toolUses: [ToolUseBlock],
        messages: [Message],
        systemPrompt: String?
    ) async throws -> [ContentBlock] {
        var results: [ContentBlock] = []
        for toolUse in toolUses {
            let result = try await executeSingleTool(
                toolUse: toolUse, messages: messages, systemPrompt: systemPrompt
            )
            results.append(.toolResult(result))
        }
        return results
    }

    private func executeSingleTool(
        toolUse: ToolUseBlock,
        messages: [Message],
        systemPrompt: String?
    ) async throws -> ToolResultBlock {
        let toolSpan = observability.startSpan(
            name: "strands.tool.invoke",
            attributes: ["tool_name": toolUse.name]
        )

        try await hookRegistry.invoke(BeforeToolCallEvent(toolUse: toolUse))

        let result: ToolResultBlock
        if let tool = toolRegistry.tool(named: toolUse.name) {
            let context = ToolContext(
                toolUse: toolUse, messages: messages, systemPrompt: systemPrompt
            )
            do {
                result = try await tool.call(toolUse: toolUse, context: context)
                observability.endSpan(toolSpan, status: .ok)
            } catch {
                result = ToolResultBlock(
                    toolUseId: toolUse.toolUseId, status: .error,
                    content: [.text("Error: \(error.localizedDescription)")]
                )
                observability.endSpan(toolSpan, status: .error(error.localizedDescription))
            }
        } else {
            result = ToolResultBlock(
                toolUseId: toolUse.toolUseId, status: .error,
                content: [.text("Tool not found: \(toolUse.name)")]
            )
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
}
