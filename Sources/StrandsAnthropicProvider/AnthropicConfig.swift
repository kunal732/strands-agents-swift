import Foundation

/// Configuration for the Anthropic API provider.
public struct AnthropicConfig: Sendable {
    /// The model ID (e.g. "claude-sonnet-4-20250514").
    public var modelId: String

    /// API key. If nil, reads from ANTHROPIC_API_KEY environment variable.
    public var apiKey: String?

    /// API base URL.
    public var baseURL: String

    /// Maximum tokens to generate.
    public var maxTokens: Int

    /// Sampling temperature.
    public var temperature: Double?

    /// Top-p nucleus sampling.
    public var topP: Double?

    /// API version header.
    public var apiVersion: String

    public init(
        modelId: String = "claude-sonnet-4-20250514",
        apiKey: String? = nil,
        baseURL: String = "https://api.anthropic.com",
        maxTokens: Int = 4096,
        temperature: Double? = nil,
        topP: Double? = nil,
        apiVersion: String = "2023-06-01"
    ) {
        self.modelId = modelId
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.apiVersion = apiVersion
    }

    /// Resolve the API key from config or environment.
    func resolvedApiKey() throws -> String {
        if let key = apiKey { return key }
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] { return key }
        throw AnthropicProviderError.missingApiKey
    }
}

enum AnthropicProviderError: Error, LocalizedError {
    case missingApiKey
    case invalidResponse(statusCode: Int, body: String)
    case streamParseError(String)

    var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "Anthropic API key not found. Set ANTHROPIC_API_KEY or pass apiKey in config."
        case .invalidResponse(let code, let body):
            return "Anthropic API error (HTTP \(code)): \(body)"
        case .streamParseError(let detail):
            return "Failed to parse stream event: \(detail)"
        }
    }
}
