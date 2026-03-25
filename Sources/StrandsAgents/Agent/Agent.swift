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

    /// Whether to execute multiple tool calls in parallel.
    /// When `true` (default), tools requested in the same turn run concurrently via TaskGroup.
    public var parallelToolExecution: Bool

    /// Hints passed to the model router on every invocation.
    ///
    /// Set this before calling `run()` or `stream()` to influence routing:
    /// ```swift
    /// agent.routingHints = RoutingHints(privacySensitive: true)
    /// let result = try await agent.run("Summarize my health records")
    ///
    /// agent.routingHints = RoutingHints(requiresDeepReasoning: true)
    /// let result = try await agent.run("Solve this multi-step proof")
    /// ```
    public var routingHints: RoutingHints = RoutingHints()

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

    /// Callback handler for streaming events (printing, logging, etc.).
    public let callbackHandler: any CallbackHandler

    // MARK: - State

    /// The conversation history.
    public private(set) var messages: [Message] = []

    /// Arbitrary key-value state that persists across invocations.
    /// Not passed to the model. Available to tools via ToolContext.
    public let state: AgentState = AgentState()

    /// Names of all registered tools.
    public var toolNames: [String] { toolRegistry.toolNames }

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
        callbackHandler: (any CallbackHandler)? = nil,
        hookProviders: [any HookProvider] = [],
        plugins: [any AgentPlugin] = [],
        maxCycles: Int = 20,
        parallelToolExecution: Bool = true
    ) {
        self.router = router
        self.toolRegistry = ToolRegistry(tools: tools)
        self.systemPrompt = systemPrompt
        self.conversationManager = conversationManager ?? SlidingWindowConversationManager()
        self.observability = observability ?? NoOpObservabilityEngine()
        self.retryStrategy = retryStrategy
        self.sessionManager = sessionManager
        self.callbackHandler = callbackHandler ?? NullCallbackHandler()
        self.hookRegistry = HookRegistry()
        self.maxCycles = maxCycles
        self.parallelToolExecution = parallelToolExecution

        // Register hook providers
        for provider in hookProviders {
            hookRegistry.register(provider: provider)
        }
        if let sm = sessionManager {
            hookRegistry.register(provider: sm)
        }

        // Apply plugins
        for plugin in plugins {
            for tool in plugin.tools {
                toolRegistry.register(tool)
            }
            plugin.configure(agent: self)
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
        callbackHandler: (any CallbackHandler)? = nil,
        hookProviders: [any HookProvider] = [],
        plugins: [any AgentPlugin] = [],
        maxCycles: Int = 20,
        parallelToolExecution: Bool = true
    ) {
        self.init(
            router: SingleProviderRouter(provider: model),
            tools: tools,
            systemPrompt: systemPrompt,
            conversationManager: conversationManager,
            observability: observability,
            retryStrategy: retryStrategy,
            sessionManager: sessionManager,
            callbackHandler: callbackHandler,
            hookProviders: hookProviders,
            plugins: plugins,
            maxCycles: maxCycles,
            parallelToolExecution: parallelToolExecution
        )
    }

    // MARK: - Public API

    /// Run the agent with the given input and return the result.
    ///
    /// If a `callbackHandler` is configured, it receives streaming events during execution.
    public func run(_ input: AgentInput) async throws -> AgentResult {
        try acquireLock()
        defer { releaseLock() }

        // Infer schemas for any Tool instances that need it
        try await resolveToolSchemas()

        appendUserInput(input)
        try await hookRegistry.invoke(BeforeInvocationEvent(messages: messages))

        let handler = self.callbackHandler
        let result = try await makeLoop().runStreaming(
            messages: &messages,
            systemPrompt: systemPrompt,
            toolChoice: nil
        ) { event in
            switch event {
            case .textDelta(let text): await handler.onTextDelta(text)
            case .contentBlock(let block): await handler.onContentBlock(block)
            case .toolResult(let r): await handler.onToolResult(r)
            case .modelMessage(let msg): await handler.onModelMessage(msg)
            case .result(let r): await handler.onResult(r)
            }
        }

        try await hookRegistry.invokeReversed(AfterInvocationEvent(result: result))
        if let sm = sessionManager {
            try? await sm.save(messages: messages)
        }

        return result
    }

    /// Run the agent with a string input.
    public func run(_ text: String) async throws -> AgentResult {
        try await run(.text(text))
    }

    /// Run the agent and parse the response as a structured output type.
    ///
    /// Registers a hidden tool that forces the model to produce output matching
    /// the schema of `T`. The model's tool call input is decoded as `T`.
    ///
    /// ```swift
    /// struct Recipe: StructuredOutput {
    ///     let name: String
    ///     let ingredients: [String]
    ///     static var jsonSchema: JSONSchema { ... }
    /// }
    /// let recipe: Recipe = try await agent.runStructured("Give me a pasta recipe")
    /// ```
    public func runStructured<T: StructuredOutput>(
        _ input: AgentInput,
        outputType: T.Type = T.self
    ) async throws -> T {
        try acquireLock()
        defer { releaseLock() }

        // Register the structured output tool temporarily
        let outputTool = StructuredOutputTool(outputType: outputType)
        toolRegistry.register(outputTool)
        defer { toolRegistry.unregister(name: outputTool.name) }

        appendUserInput(input)
        try await hookRegistry.invoke(BeforeInvocationEvent(messages: messages))

        // Force the model to use the structured output tool
        let result = try await makeLoop().run(
            messages: &messages,
            systemPrompt: systemPrompt,
            toolChoice: .tool(name: outputTool.name)
        )

        try await hookRegistry.invokeReversed(AfterInvocationEvent(result: result))

        // Find the tool use block with the structured output
        let allToolUses = messages.flatMap(\.toolUses)
        guard let outputToolUse = allToolUses.last(where: { $0.name == outputTool.name }) else {
            throw StrandsError.structuredOutputFailed(reason: "Model did not produce structured output")
        }

        // Decode the tool input as the output type
        let data = try JSONEncoder().encode(outputToolUse.input)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw StrandsError.structuredOutputFailed(reason: "Failed to decode output: \(error.localizedDescription)")
        }
    }

    /// Run structured output with a string input.
    public func runStructured<T: StructuredOutput>(_ text: String, outputType: T.Type = T.self) async throws -> T {
        try await runStructured(.text(text), outputType: outputType)
    }

    /// Stream agent events as they occur.
    public func stream(_ input: AgentInput) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try self.acquireLock()

                    try await self.resolveToolSchemas()
                    self.appendUserInput(input)

                    try await self.hookRegistry.invoke(BeforeInvocationEvent(messages: self.messages))

                    let loop = self.makeLoop()

                    let handler = self.callbackHandler
                    let result = try await loop.runStreaming(
                        messages: &self.messages,
                        systemPrompt: self.systemPrompt,
                        toolChoice: nil
                    ) { event in
                        continuation.yield(event)
                        // Also dispatch to callback handler
                        switch event {
                        case .textDelta(let text): await handler.onTextDelta(text)
                        case .contentBlock(let block): await handler.onContentBlock(block)
                        case .toolResult(let r): await handler.onToolResult(r)
                        case .modelMessage(let msg): await handler.onModelMessage(msg)
                        case .result(let r): await handler.onResult(r)
                        }
                    }

                    try await self.hookRegistry.invokeReversed(AfterInvocationEvent(result: result))
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

    // MARK: - Direct Tool Calling

    /// Call a registered tool directly without going through the model.
    ///
    /// ```swift
    /// let result = try await agent.callTool("calculator", input: ["expression": "2+2"])
    /// ```
    ///
    /// - Parameters:
    ///   - name: The tool name.
    ///   - input: The tool input as a JSONValue.
    ///   - recordInHistory: Whether to record the call in conversation history.
    /// - Returns: The tool result.
    public func callTool(
        _ name: String,
        input: JSONValue = .object([:]),
        recordInHistory: Bool = true
    ) async throws -> ToolResultBlock {
        guard let tool = toolRegistry.tool(named: name) else {
            throw StrandsError.toolNotFound(name: name)
        }

        let toolUseId = UUID().uuidString
        let toolUse = ToolUseBlock(toolUseId: toolUseId, name: name, input: input)
        let context = ToolContext(
            toolUse: toolUse,
            messages: messages,
            systemPrompt: systemPrompt,
            agentState: state
        )

        let result = try await tool.call(toolUse: toolUse, context: context)

        if recordInHistory {
            messages.append(Message(role: .assistant, content: [.toolUse(toolUse)]))
            messages.append(Message(role: .user, content: [.toolResult(result)]))
        }

        return result
    }

    // MARK: - Interrupt Resume

    /// Resume agent execution after an interrupt.
    ///
    /// Call this after catching an `InterruptError` to provide the human's response
    /// and continue the agent loop.
    public func resume(interruptResponse: InterruptResponse) async throws -> AgentResult {
        // Add the interrupt response as a user message
        let responseMessage = Message.user(
            "[\(interruptResponse.name)] \(interruptResponse.response)"
        )
        messages.append(responseMessage)

        try acquireLock()
        defer { releaseLock() }

        return try await makeLoop().run(
            messages: &messages,
            systemPrompt: systemPrompt,
            toolChoice: nil
        )
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
            maxCycles: maxCycles,
            parallelToolExecution: parallelToolExecution,
            agentState: state,
            routingHints: routingHints
        )
    }

    /// Resolve schemas for any Tool instances that haven't been inferred yet.
    private func resolveToolSchemas() async throws {
        // Collect tools that need inference
        var unresolvedIndices: [(index: Int, tool: Tool)] = []
        for (i, agentTool) in toolRegistry.allTools.enumerated() {
            if let tool = agentTool as? Tool, tool.needsInference {
                unresolvedIndices.append((i, tool))
            }
        }
        guard !unresolvedIndices.isEmpty else { return }

        // Build inference prompt
        let toolInfos = unresolvedIndices.enumerated().map { (offset, pair) in
            (index: offset, description: pair.tool.toolSpec.description, paramTypes: pair.tool.paramTypes)
        }
        let prompt = ToolSchemaInference.buildInferencePrompt(tools: toolInfos)

        // Ask the model
        let ctx = RoutingContext(messages: [.user(prompt)], toolSpecs: nil, systemPrompt: nil,
                                  hints: routingHints, deviceCapabilities: .current)
        let provider = try await router.route(context: ctx)
        let stream = provider.stream(messages: [.user(prompt)], toolSpecs: nil, systemPrompt: "You are a tool naming assistant. Return only JSON.", toolChoice: nil)
        let result = try await StreamAggregator().aggregate(stream: stream)
        let responseText = result.message.textContent ?? ""

        // Parse and apply
        guard let schemas = ToolSchemaInference.parseInferenceResponse(responseText) else { return }

        for (offset, pair) in unresolvedIndices.enumerated() {
            guard offset < schemas.count else { continue }
            let schema = schemas[offset]
            var tool = pair.tool
            tool.resolveSchema(toolName: schema.name, paramNames: schema.params)
            toolRegistry.updateTool(at: pair.index, with: tool)
        }
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
