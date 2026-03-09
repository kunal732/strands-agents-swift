import Foundation

/// Build an Agent from a JSON configuration dictionary.
///
/// Enables declarative agent creation from config files, remote configs,
/// or admin dashboards.
///
/// ```swift
/// let config: [String: Any] = [
///     "model_id": "us.anthropic.claude-sonnet-4-20250514-v1:0",
///     "system_prompt": "You are a helpful assistant.",
///     "max_cycles": 10,
///     "parallel_tool_execution": true,
///     "region": "us-east-1",
/// ]
///
/// let agent = try AgentConfig.build(from: config, modelFactory: { id, region in
///     try BedrockProvider(config: BedrockConfig(modelId: id, region: region ?? "us-east-1"))
/// })
/// ```
public enum AgentConfig {

    /// Configuration keys.
    public enum Key {
        public static let modelId = "model_id"
        public static let systemPrompt = "system_prompt"
        public static let maxCycles = "max_cycles"
        public static let parallelToolExecution = "parallel_tool_execution"
        public static let region = "region"
        public static let temperature = "temperature"
        public static let maxTokens = "max_tokens"
    }

    /// Build an Agent from a configuration dictionary.
    ///
    /// - Parameters:
    ///   - config: Configuration dictionary with string keys.
    ///   - tools: Tools to register with the agent.
    ///   - modelFactory: Closure that creates a ModelProvider from a model ID and optional region.
    /// - Returns: A configured Agent.
    public static func build(
        from config: [String: Any],
        tools: [any AgentTool] = [],
        modelFactory: (String, String?) throws -> any ModelProvider
    ) throws -> Agent {
        let modelId = config[Key.modelId] as? String ?? "us.anthropic.claude-sonnet-4-20250514-v1:0"
        let region = config[Key.region] as? String
        let systemPrompt = config[Key.systemPrompt] as? String
        let maxCycles = config[Key.maxCycles] as? Int ?? 20
        let parallel = config[Key.parallelToolExecution] as? Bool ?? true

        let provider = try modelFactory(modelId, region)

        return Agent(
            model: provider,
            tools: tools,
            systemPrompt: systemPrompt,
            maxCycles: maxCycles,
            parallelToolExecution: parallel
        )
    }

    /// Build an Agent from JSON data.
    public static func build(
        fromJSON data: Data,
        tools: [any AgentTool] = [],
        modelFactory: (String, String?) throws -> any ModelProvider
    ) throws -> Agent {
        let config = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return try build(from: config, tools: tools, modelFactory: modelFactory)
    }
}
