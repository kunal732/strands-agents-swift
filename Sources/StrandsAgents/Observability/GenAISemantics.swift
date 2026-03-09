import Foundation

/// OpenTelemetry Gen AI semantic convention attribute names.
///
/// These match the attributes that Datadog LLM Observability, Langfuse,
/// and other OTel-compatible backends look for to populate their LLM
/// tracing UIs.
///
/// Reference: https://github.com/open-telemetry/semantic-conventions/blob/main/docs/gen-ai/
public enum GenAIAttributes {
    // MARK: - Agent
    public static let agentName = "gen_ai.agent.name"
    public static let agentTools = "gen_ai.agent.tools"

    // MARK: - Request
    public static let requestModel = "gen_ai.request.model"
    public static let operationName = "gen_ai.operation.name"
    public static let system = "gen_ai.system"

    // MARK: - Usage
    public static let usageInputTokens = "gen_ai.usage.input_tokens"
    public static let usageOutputTokens = "gen_ai.usage.output_tokens"
    public static let usageTotalTokens = "gen_ai.usage.total_tokens"
    public static let usagePromptTokens = "gen_ai.usage.prompt_tokens"
    public static let usageCompletionTokens = "gen_ai.usage.completion_tokens"
    public static let usageCacheReadInputTokens = "gen_ai.usage.cache_read_input_tokens"
    public static let usageCacheWriteInputTokens = "gen_ai.usage.cache_write_input_tokens"

    // MARK: - Latency
    public static let serverTimeToFirstToken = "gen_ai.server.time_to_first_token"
    public static let serverRequestDuration = "gen_ai.server.request.duration"

    // MARK: - Tool
    public static let toolName = "gen_ai.tool.name"
    public static let toolCallId = "gen_ai.tool.call.id"
    public static let toolStatus = "gen_ai.tool.status"

    // MARK: - Timing
    public static let eventStartTime = "gen_ai.event.start_time"
    public static let eventEndTime = "gen_ai.event.end_time"

    // MARK: - Event Loop
    public static let eventLoopCycleId = "event_loop.cycle_id"
}

/// Standard span names matching the Python Strands SDK.
public enum GenAISpanNames {
    public static let invokeAgent = "invoke_agent"
    public static let chat = "chat"
    public static let executeTool = "execute_tool"
    public static let eventLoopCycle = "execute_event_loop_cycle"
}

/// Standard event names for OTel Gen AI semantic conventions.
public enum GenAIEventNames {
    public static let userMessage = "gen_ai.user.message"
    public static let assistantMessage = "gen_ai.assistant.message"
    public static let toolMessage = "gen_ai.tool.message"
    public static let choice = "gen_ai.choice"
}
