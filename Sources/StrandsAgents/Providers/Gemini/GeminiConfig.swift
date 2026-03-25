import Foundation

/// Configuration for the Google Gemini API provider.
public struct GeminiConfig: Sendable {
    /// The model ID (e.g. "gemini-2.5-flash", "gemini-2.5-pro").
    public var modelId: String

    /// API key. If nil, reads from GOOGLE_API_KEY environment variable.
    public var apiKey: String?

    /// API base URL.
    public var baseURL: String

    /// Maximum tokens to generate.
    public var maxTokens: Int

    /// Sampling temperature.
    public var temperature: Double?

    /// Top-p nucleus sampling.
    public var topP: Double?

    public init(
        modelId: String = "gemini-2.5-flash",
        apiKey: String? = nil,
        baseURL: String = "https://generativelanguage.googleapis.com/v1beta",
        maxTokens: Int = 4096,
        temperature: Double? = nil,
        topP: Double? = nil
    ) {
        self.modelId = modelId
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
    }

    func resolvedApiKey() throws -> String {
        if let key = apiKey { return key }
        if let key = ProcessInfo.processInfo.environment["GOOGLE_API_KEY"] { return key }
        throw GeminiProviderError.missingApiKey
    }
}

enum GeminiProviderError: Error, LocalizedError {
    case missingApiKey
    case invalidResponse(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "Google API key not found. Set GOOGLE_API_KEY or pass apiKey in config."
        case .invalidResponse(let code, let body):
            return "Gemini API error (HTTP \(code)): \(body)"
        }
    }
}
