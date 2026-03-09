import Foundation
import StrandsAgents

/// Protocol for models that support bidirectional streaming.
///
/// Unlike regular `ModelProvider` which uses request-response,
/// a `BidiModel` maintains an open connection where input and output
/// flow simultaneously.
///
/// Implementations:
/// - Cloud: OpenAI Realtime API, AWS Nova Sonic, Google Gemini Live
/// - Local: MLX pipeline (STT -> LLM -> TTS)
public protocol BidiModel: Sendable {
    /// A human-readable identifier for this model.
    var modelId: String? { get }

    /// Model-specific configuration (audio rates, voice, etc.).
    var config: [String: Any] { get }

    /// Start the streaming connection.
    ///
    /// Establishes a persistent connection to the model and configures it
    /// with the system prompt, tools, and conversation history.
    func start(
        systemPrompt: String?,
        tools: [ToolSpec],
        messages: [Message]
    ) async throws

    /// Stop the streaming connection.
    func stop() async

    /// Send an input event or tool result to the model.
    func send(_ event: BidiInputEvent) async throws

    /// Send a tool result back to the model.
    func sendToolResult(_ result: ToolResultBlock) async throws

    /// Receive output events from the model.
    ///
    /// This is a long-running async sequence that yields events
    /// until the connection closes or an error occurs.
    func receive() -> AsyncThrowingStream<BidiOutputEvent, Error>
}

/// Error thrown when the model connection times out.
///
/// The bidi agent loop catches this and automatically reconnects,
/// restoring the conversation from message history.
public struct BidiModelTimeoutError: Error, Sendable {
    public let message: String

    public init(message: String = "Model connection timed out") {
        self.message = message
    }
}
