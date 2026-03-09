import Foundation
import StrandsAgents

// MARK: - Bidi Events

/// Events flowing FROM the user TO the model (input direction).
public enum BidiInputEvent: Sendable {
    /// Raw audio data from microphone.
    case audio(Data, format: AudioFormat)

    /// Text input from user.
    case text(String)

    /// Image frame (e.g. from camera).
    case image(Data, mimeType: String)

    /// User interrupted the model's response.
    case interrupt

    /// Session control.
    case sessionUpdate(BidiSessionConfig)

    /// End the conversation.
    case end
}

/// Events flowing FROM the model TO the user (output direction).
public enum BidiOutputEvent: Sendable {
    /// Streamed audio response chunk.
    case audio(Data, format: AudioFormat)

    /// Streamed text response chunk (partial transcript).
    case textDelta(String)

    /// Complete text transcript of what the model or user said.
    case transcript(role: Role, text: String, isFinal: Bool)

    /// Connection to model established.
    case connectionStarted(connectionId: String)

    /// Connection to model is restarting (e.g. timeout).
    case connectionRestarting

    /// The model detected the user started speaking.
    case inputSpeechStarted

    /// The model finished processing user speech.
    case inputSpeechDone(transcript: String)

    /// The model started generating a response.
    case responseStarted(responseId: String)

    /// The model finished generating a response.
    case responseDone(responseId: String)

    /// Tool call requested by the model.
    case toolCall(ToolUseBlock)

    /// Tool result fed back to the model.
    case toolResult(ToolResultBlock)

    /// Token usage for this exchange.
    case usage(Usage)

    /// The model interrupted its own response (user started speaking).
    case interruption(reason: InterruptionReason)

    /// Error occurred.
    case error(String)

    /// Session ended.
    case sessionEnded(reason: SessionEndReason)
}

public enum InterruptionReason: String, Sendable {
    case userSpeech = "user_speech"
    case error = "error"
}

public enum SessionEndReason: String, Sendable {
    case clientDisconnect = "client_disconnect"
    case timeout = "timeout"
    case error = "error"
    case complete = "complete"
    case userRequest = "user_request"
}

// MARK: - Audio Format

/// Audio encoding and format configuration.
public struct AudioFormat: Sendable, Hashable {
    public var encoding: AudioEncoding
    public var sampleRate: Int
    public var channels: Int

    public init(encoding: AudioEncoding = .pcm16, sampleRate: Int = 24000, channels: Int = 1) {
        self.encoding = encoding
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// Standard format for OpenAI Realtime API.
    public static let openAI = AudioFormat(encoding: .pcm16, sampleRate: 24000, channels: 1)

    /// Standard format for Nova Sonic.
    public static let novaSonic = AudioFormat(encoding: .pcm16, sampleRate: 16000, channels: 1)

    /// Standard format for Gemini Live.
    public static let geminiLive = AudioFormat(encoding: .pcm16, sampleRate: 16000, channels: 1)

    /// Standard format for local MLX processing.
    public static let mlxDefault = AudioFormat(encoding: .pcm16, sampleRate: 16000, channels: 1)
}

public enum AudioEncoding: String, Sendable, Hashable {
    case pcm16 = "pcm16"
    case opus = "opus"
    case mp3 = "mp3"
    case flac = "flac"
}

// MARK: - Session Config

/// Configuration for a bidi streaming session.
public struct BidiSessionConfig: Sendable {
    /// System prompt / instructions.
    public var instructions: String?

    /// Voice to use for TTS (model-dependent).
    public var voice: String?

    /// Input audio format.
    public var inputAudioFormat: AudioFormat

    /// Output audio format.
    public var outputAudioFormat: AudioFormat

    /// Whether to enable voice activity detection.
    public var vadEnabled: Bool

    /// Tools available to the model.
    public var tools: [ToolSpec]

    /// Turn detection mode.
    public var turnDetection: TurnDetection

    public init(
        instructions: String? = nil,
        voice: String? = nil,
        inputAudioFormat: AudioFormat = .mlxDefault,
        outputAudioFormat: AudioFormat = .mlxDefault,
        vadEnabled: Bool = true,
        tools: [ToolSpec] = [],
        turnDetection: TurnDetection = .serverVAD()
    ) {
        self.instructions = instructions
        self.voice = voice
        self.inputAudioFormat = inputAudioFormat
        self.outputAudioFormat = outputAudioFormat
        self.vadEnabled = vadEnabled
        self.tools = tools
        self.turnDetection = turnDetection
    }
}

/// How turn-taking is detected in a bidi conversation.
public enum TurnDetection: Sendable {
    /// Server/model detects when the user stops speaking.
    case serverVAD(silenceDurationMs: Int = 500, threshold: Double = 0.5)

    /// Client explicitly signals turn boundaries.
    case manual
}

// MARK: - I/O Protocols

/// A source of input events for a bidi agent.
///
/// Implementations: microphone capture, text input, WebSocket receiver, etc.
public protocol BidiInput: Sendable {
    /// Start the input source.
    func start(agent: BidiAgent) async throws

    /// Read the next input event. Returns nil when done.
    func nextEvent() async throws -> BidiInputEvent?

    /// Stop the input source.
    func stop() async
}

/// A destination for output events from a bidi agent.
///
/// Implementations: speaker playback, text display, WebSocket sender, etc.
public protocol BidiOutput: Sendable {
    /// Start the output destination.
    func start(agent: BidiAgent) async throws

    /// Handle an output event.
    func handle(_ event: BidiOutputEvent) async throws

    /// Stop the output destination.
    func stop() async
}
