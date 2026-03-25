import Foundation

/// An agent that supports bidirectional streaming for real-time voice/text conversations.
///
/// Unlike the regular `Agent` which processes one request at a time, `BidiAgent`
/// maintains a continuous session where input and output flow simultaneously.
///
/// ## Usage: Manual send/receive
///
/// ```swift
/// let agent = BidiAgent(model: OpenAIRealtimeModel(), tools: [WeatherTool()])
///
/// try await agent.start()
///
/// // Send in one task
/// Task { for await chunk in mic.audioStream { try await agent.send(.audio(chunk, format: .openAI)) } }
///
/// // Receive in another
/// for try await event in agent.receive() {
///     if case .audio(let data, _) = event { speaker.play(data) }
/// }
///
/// await agent.stop()
/// ```
///
/// ## Usage: Pluggable I/O
///
/// ```swift
/// let agent = BidiAgent(model: OpenAIRealtimeModel(), tools: [WeatherTool()])
/// try await agent.run(inputs: [micInput], outputs: [speakerOutput, textDisplay])
/// ```
public final class BidiAgent: @unchecked Sendable {
    /// The bidirectional model.
    public let model: any BidiModel

    /// Available tools.
    public let toolRegistry: ToolRegistry

    /// System prompt.
    public let systemPrompt: String?

    /// Session configuration.
    public let config: BidiSessionConfig

    /// Hook registry for bidi-specific events.
    public let hookRegistry: HookRegistry

    /// Conversation history (updated as the session progresses).
    public private(set) var messages: [Message] = []

    private let messageLock = NSLock()
    private var started = false
    private var eventContinuation: AsyncThrowingStream<BidiOutputEvent, Error>.Continuation?
    private var eventStream: AsyncThrowingStream<BidiOutputEvent, Error>?
    private var modelReceiveTask: Task<Void, Never>?
    private var inputTasks: [Task<Void, Never>] = []

    public init(
        model: any BidiModel,
        tools: [any AgentTool] = [],
        systemPrompt: String? = nil,
        config: BidiSessionConfig = BidiSessionConfig(),
        hookRegistry: HookRegistry = HookRegistry()
    ) {
        self.model = model
        self.toolRegistry = ToolRegistry(tools: tools)
        self.systemPrompt = systemPrompt
        self.hookRegistry = hookRegistry

        // Merge tool specs into config + add stop_conversation
        var sessionConfig = config
        sessionConfig.tools = toolRegistry.toolSpecs
        self.config = sessionConfig

        // Register built-in stop_conversation tool
        toolRegistry.register(StopConversationTool(agent: self))
    }

    // MARK: - Lifecycle

    /// Start the bidirectional session.
    public func start() async throws {
        guard !started else { return }
        started = true

        let (stream, continuation) = AsyncThrowingStream<BidiOutputEvent, Error>.makeStream()
        self.eventStream = stream
        self.eventContinuation = continuation

        try await model.start(
            systemPrompt: config.instructions ?? systemPrompt,
            tools: config.tools,
            messages: messages
        )

        // Start model receive loop in background
        modelReceiveTask = Task { [weak self] in
            await self?.modelReceiveLoop()
        }
    }

    /// Stop the session.
    public func stop() async {
        guard started else { return }
        started = false

        // Cancel all input tasks
        for task in inputTasks { task.cancel() }
        inputTasks.removeAll()

        // Cancel model receive
        modelReceiveTask?.cancel()
        modelReceiveTask = nil

        await model.stop()

        eventContinuation?.yield(.sessionEnded(reason: .clientDisconnect))
        eventContinuation?.finish()
        eventContinuation = nil
        eventStream = nil
    }

    // MARK: - Send / Receive

    /// Send an input event to the model.
    public func send(_ event: BidiInputEvent) async throws {
        guard started else { return }
        try await model.send(event)
    }

    /// Receive output events from the model.
    ///
    /// Tool calls are automatically executed and results sent back to the model.
    public func receive() -> AsyncThrowingStream<BidiOutputEvent, Error> {
        guard let stream = eventStream else {
            return AsyncThrowingStream { $0.finish() }
        }
        return stream
    }

    // MARK: - High-Level I/O

    /// Run the agent with pluggable input/output channels.
    ///
    /// Starts the session, reads from all inputs concurrently, dispatches all
    /// output events to all outputs, and stops when the session ends.
    ///
    /// ```swift
    /// try await agent.run(
    ///     inputs: [microphoneInput],
    ///     outputs: [speakerOutput, transcriptDisplay]
    /// )
    /// ```
    public func run(
        inputs: [any BidiInput],
        outputs: [any BidiOutput]
    ) async throws {
        try await start()
        defer { Task { await stop() } }

        // Start all I/O
        for input in inputs { try await input.start(agent: self) }
        for output in outputs { try await output.start(agent: self) }

        // Start input reading tasks
        for input in inputs {
            let task = Task { [weak self] in
                guard let self else { return }
                while self.started {
                    do {
                        guard let event = try await input.nextEvent() else { break }
                        try await self.send(event)
                    } catch {
                        break
                    }
                }
            }
            inputTasks.append(task)
        }

        // Process output events
        for try await event in receive() {
            for output in outputs {
                try await output.handle(event)
            }

            if case .sessionEnded = event { break }
        }

        // Stop all I/O
        for input in inputs { await input.stop() }
        for output in outputs { await output.stop() }
    }

    // MARK: - Internal

    /// Append a message to conversation history (thread-safe).
    func appendMessage(_ message: Message) {
        messageLock.withLock { messages.append(message) }
    }

    /// Signal that the conversation should end (called by stop_conversation tool).
    func signalStop() {
        eventContinuation?.yield(.sessionEnded(reason: .userRequest))
        Task { await stop() }
    }

    private func modelReceiveLoop() async {
        let stream = model.receive()

        do {
            for try await event in stream {
                guard started else { break }

                // Handle tool calls
                if case .toolCall(let toolUse) = event {
                    eventContinuation?.yield(event)
                    await handleToolCall(toolUse)
                    continue
                }

                // Track transcripts in message history
                if case .transcript(let role, let text, let isFinal) = event, isFinal {
                    appendMessage(Message(role: role, content: [.text(TextBlock(text: text))]))
                }

                eventContinuation?.yield(event)
            }
        } catch is BidiModelTimeoutError {
            // Auto-reconnect
            eventContinuation?.yield(.connectionRestarting)
            do {
                try await model.start(
                    systemPrompt: config.instructions ?? systemPrompt,
                    tools: config.tools,
                    messages: messages
                )
                // Restart receive loop
                modelReceiveTask = Task { [weak self] in
                    await self?.modelReceiveLoop()
                }
            } catch {
                eventContinuation?.yield(.error("Reconnection failed: \(error.localizedDescription)"))
                eventContinuation?.yield(.sessionEnded(reason: .error))
                eventContinuation?.finish()
            }
        } catch {
            eventContinuation?.yield(.error(error.localizedDescription))
            eventContinuation?.yield(.sessionEnded(reason: .error))
            eventContinuation?.finish()
        }
    }

    private func handleToolCall(_ toolUse: ToolUseBlock) async {
        guard let tool = toolRegistry.tool(named: toolUse.name) else {
            let errorResult = ToolResultBlock(
                toolUseId: toolUse.toolUseId, status: .error,
                content: [.text("Tool not found: \(toolUse.name)")]
            )
            eventContinuation?.yield(.toolResult(errorResult))
            try? await model.sendToolResult(errorResult)
            return
        }

        let context = ToolContext(toolUse: toolUse, messages: messages, systemPrompt: systemPrompt)

        do {
            let result = try await tool.call(toolUse: toolUse, context: context)
            eventContinuation?.yield(.toolResult(result))

            // Record in message history (atomic pair)
            messageLock.withLock {
                messages.append(Message(role: .assistant, content: [.toolUse(toolUse)]))
                messages.append(Message(role: .user, content: [.toolResult(result)]))
            }

            // Don't send result for stop_conversation (it closes the session)
            if toolUse.name != "stop_conversation" {
                try await model.sendToolResult(result)
            }
        } catch {
            let errorResult = ToolResultBlock(
                toolUseId: toolUse.toolUseId, status: .error,
                content: [.text("Error: \(error.localizedDescription)")]
            )
            eventContinuation?.yield(.toolResult(errorResult))
            try? await model.sendToolResult(errorResult)
        }
    }
}

// MARK: - Built-in Stop Tool

/// Built-in tool that allows the model to gracefully end the conversation.
private struct StopConversationTool: AgentTool {
    let name = "stop_conversation"
    var toolSpec: ToolSpec {
        ToolSpec(
            name: "stop_conversation",
            description: "Stop the bidirectional conversation gracefully. Call this when the user says goodbye or the conversation is complete.",
            inputSchema: ["type": "object"]
        )
    }

    private weak var agent: BidiAgent?

    init(agent: BidiAgent) {
        self.agent = agent
    }

    func call(toolUse: ToolUseBlock, context: ToolContext) async throws -> ToolResultBlock {
        agent?.signalStop()
        return ToolResultBlock(
            toolUseId: toolUse.toolUseId,
            status: .success,
            content: [.text("Ending conversation.")]
        )
    }
}
