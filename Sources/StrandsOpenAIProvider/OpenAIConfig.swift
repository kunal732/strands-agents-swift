import Foundation

/// Configuration for the OpenAI API provider.
public struct OpenAIConfig: Sendable {
    /// The model ID (e.g. "gpt-4o", "gpt-4o-mini").
    public var modelId: String

    /// API key. If nil, reads from OPENAI_API_KEY environment variable.
    public var apiKey: String?

    /// API base URL. Change this for Azure OpenAI or compatible APIs.
    public var baseURL: String

    /// Maximum tokens to generate.
    public var maxTokens: Int

    /// Sampling temperature.
    public var temperature: Double?

    /// Top-p nucleus sampling.
    public var topP: Double?

    public init(
        modelId: String = "gpt-4o",
        apiKey: String? = nil,
        baseURL: String = "https://api.openai.com/v1",
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
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] { return key }
        throw OpenAIProviderError.missingApiKey
    }
}

enum OpenAIProviderError: Error, LocalizedError {
    case missingApiKey
    case invalidResponse(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "OpenAI API key not found. Set OPENAI_API_KEY or pass apiKey in config."
        case .invalidResponse(let code, let body):
            return "OpenAI API error (HTTP \(code)): \(body)"
        }
    }
}
