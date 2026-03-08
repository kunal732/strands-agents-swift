import Foundation

/// An AI agent that combines a model, tools, and a reasoning loop.
///
/// ```swift
/// let agent = Agent(model: myProvider, tools: [CalculatorTool()])
/// let result = try await agent.run("What is 42 * 17?")
/// print(result)
/// ```
///
/// The agent maintains conversation history across calls. Each call to `run()` or
/// `stream()` adds the user message and assistant response to the history.
public final class Agent: @unchecked Sendable {
    // MARK: - Configuration

    /// The system prompt sent with every model call.
    public var systemPrompt: String?

    /// Maximum number of agent loop cycles per invocation.
    public var maxCycles: Int

    // MARK: - Components

    /// The model router (selects which provider to use).
    public let router: any ModelRouter

    /// Registry of available tools.
    public let toolRegistry: ToolRegistry

    /// Manages conversation history length.
    public let conversationManager: any ConversationManager

    /// Hook registry for lifecycle events.
    public let hookRegistry: HookRegistry

    /// Observability engine for tracing and metrics.
    public let observability: any ObservabilityEngine

    /// Retry strategy for model calls.
    public let retryStrategy: RetryStrategy

    /// Session manager for persistence (optional).
    public let sessionManager: SessionManager?

    // MARK: - State

    /// The conversation history.
    public private(set) var messages: [Message] = []

    /// Concurrency lock to prevent reentrant invocations.
    private let lock = NSLock()
    private var isRunning = false

    // MARK: - Initialization

    /// Create an agent with a model router.
    public init(
        router: any ModelRouter,
        tools: [any AgentTool] = [],
        systemPrompt: String? = nil,
        conversationManager: (any ConversationManager)? = nil,
        observability: (any ObservabilityEngine)? = nil,
        retryStrategy: RetryStrategy = RetryStrategy(),
        sessionManager: SessionManager? = nil,
        hookProviders: [any HookProvider] = [],
        maxCycles: Int = 20
    ) {
        self.router = router
        self.toolRegistry = ToolRegistry(tools: tools)
        self.systemPrompt = systemPrompt
        self.conversationManager = conversationManager ?? SlidingWindowConversationManager()
        self.observability = observability ?? NoOpObservabilityEngine()
        self.retryStrategy = retryStrategy
        self.sessionManager = sessionManager
        self.hookRegistry = HookRegistry()
        self.maxCycles = maxCycles

        // Register hook providers
        for provider in hookProviders {
            hookRegistry.register(provider: provider)
        }
        if let sm = sessionManager {
            hookRegistry.register(provider: sm)
        }
    }

    /// Create an agent with a single model provider (no routing).
    public convenience init(
        model: any ModelProvider,
        tools: [any AgentTool] = [],
        systemPrompt: String? = nil,
        conversationManager: (any ConversationManager)? = nil,
        observability: (any ObservabilityEngine)? = nil,
        retryStrategy: RetryStrategy = RetryStrategy(),
        sessionManager: SessionManager? = nil,
        hookProviders: [any HookProvider] = [],
        maxCycles: Int = 20
    ) {
        self.init(
            router: SingleProviderRouter(provider: model),
            tools: tools,
            systemPrompt: systemPrompt,
            conversationManager: conversationManager,
            observability: observability,
            retryStrategy: retryStrategy,
            sessionManager: sessionManager,
            hookProviders: hookProviders,
            maxCycles: maxCycles
        )
    }

    // MARK: - Public API

    /// Run the agent with the given input and return the result.
    ///
    /// This is the primary entry point. The agent will:
    /// 1. Append the user message to conversation history
    /// 2. Enter the reasoning loop (model calls + tool calls)
    /// 3. Return the final result
    ///
    /// - Parameter input: The user's message.
    /// - Returns: The agent's response.
    public func run(_ input: AgentInput) async throws -> AgentResult {
        try acquireLock()
        defer { releaseLock() }

        // Normalize input to messages
        appendUserInput(input)

        // Emit before invocation hook
        try await hookRegistry.invoke(BeforeInvocationEvent(messages: messages))

        // Run the loop
        let result = try await makeLoop().run(
            messages: &messages,
            systemPrompt: systemPrompt,
            toolChoice: nil
        )

        // Emit after invocation hook
        try await hookRegistry.invoke(AfterInvocationEvent(result: result))

        // Save session if configured
        if let sm = sessionManager {
            try? await sm.save(messages: messages)
        }

        return result
    }

    /// Run the agent with a string input.
    public func run(_ text: String) async throws -> AgentResult {
        try await run(.text(text))
    }

    /// Stream agent events as they occur.
    ///
    /// Returns an `AsyncThrowingStream` that yields text deltas, content blocks,
    /// tool results, and model messages as they happen. The stream ends with
    /// a `.result` event containing the final `AgentResult`.
    ///
    /// ```swift
    /// for try await event in agent.stream("Tell me a story") {
    ///     switch event {
    ///     case .textDelta(let text): print(text, terminator: "")
    ///     case .result(let result): print("\nDone: \(result.stopReason)")
    ///     default: break
    ///     }
    /// }
    /// ```
    public func stream(_ input: AgentInput) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try self.acquireLock()

                    self.appendUserInput(input)

                    try await self.hookRegistry.invoke(BeforeInvocationEvent(messages: self.messages))

                    let loop = self.makeLoop()

                    let result = try await loop.runStreaming(
                        messages: &self.messages,
                        systemPrompt: self.systemPrompt,
                        toolChoice: nil
                    ) { event in
                        continuation.yield(event)
                    }

                    try await self.hookRegistry.invoke(AfterInvocationEvent(result: result))
                    if let sm = self.sessionManager {
                        try? await sm.save(messages: self.messages)
                    }

                    continuation.finish()
                    self.releaseLock()
                } catch {
                    self.releaseLock()
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Stream agent events with a string input.
    public func stream(_ text: String) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        stream(.text(text))
    }

    /// Reset conversation history.
    public func resetConversation() {
        messages = []
    }

    /// Restore a previous session.
    public func restoreSession() async throws -> Bool {
        guard let sm = sessionManager else { return false }
        guard let restored = try await sm.restore() else { return false }
        messages = restored
        return true
    }

    // MARK: - Private

    private func makeLoop() -> AgentLoop {
        AgentLoop(
            router: router,
            toolRegistry: toolRegistry,
            conversationManager: conversationManager,
            hookRegistry: hookRegistry,
            observability: observability,
            retryStrategy: retryStrategy,
            maxCycles: maxCycles
        )
    }

    private func appendUserInput(_ input: AgentInput) {
        switch input {
        case .text(let text):
            messages.append(.user(text))
        case .contentBlocks(let blocks):
            messages.append(Message(role: .user, content: blocks))
        case .messages(let msgs):
            messages.append(contentsOf: msgs)
        }
    }

    private func acquireLock() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else {
            throw StrandsError.cancelled
        }
        isRunning = true
    }

    private func releaseLock() {
        lock.lock()
        defer { lock.unlock() }
        isRunning = false
    }
}
