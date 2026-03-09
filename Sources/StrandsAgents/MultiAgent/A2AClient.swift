import Foundation

/// Client for calling remote agents via the Agent-to-Agent (A2A) protocol.
///
/// Wraps a remote A2A-compatible agent as an `AgentTool`, allowing it to be
/// called by a local agent as if it were a regular tool.
///
/// ```swift
/// let remoteAgent = A2AClient(
///     name: "research_agent",
///     description: "A remote research agent",
///     endpoint: URL(string: "https://research-agent.example.com")!
/// )
///
/// let agent = Agent(model: provider, tools: [remoteAgent])
/// let result = try await agent.run("Research quantum computing")
/// ```
public final class A2AClient: AgentTool, @unchecked Sendable {
    public let name: String
    public let toolSpec: ToolSpec
    private let endpoint: URL
    private let session: URLSession

    /// The remote agent's card (capabilities, skills), fetched on first use.
    public private(set) var agentCard: [String: Any]?

    public init(
        name: String,
        description: String,
        endpoint: URL
    ) {
        self.name = name
        self.endpoint = endpoint
        self.session = URLSession(configuration: .default)
        self.toolSpec = ToolSpec(
            name: name,
            description: description,
            inputSchema: [
                "type": "object",
                "properties": [
                    "task": [
                        "type": "string",
                        "description": "The task to send to the remote agent",
                    ],
                ],
                "required": ["task"],
            ]
        )
    }

    /// Fetch the remote agent's capability card.
    public func fetchAgentCard() async throws -> [String: Any] {
        let url = endpoint.appendingPathComponent(".well-known/agent.json")
        let (data, _) = try await session.data(from: url)
        let card = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        self.agentCard = card
        return card
    }

    public func call(toolUse: ToolUseBlock, context: ToolContext) async throws -> ToolResultBlock {
        let task = toolUse.input["task"]?.foundationValue as? String ?? ""

        // Build A2A task request
        let requestBody: [String: Any] = [
            "id": UUID().uuidString,
            "message": [
                "role": "user",
                "parts": [["type": "text", "text": task]],
            ],
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: endpoint.appendingPathComponent("tasks/send"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (responseData, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return ToolResultBlock(
                toolUseId: toolUse.toolUseId, status: .error,
                content: [.text("A2A request failed")]
            )
        }

        // Parse A2A response
        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let artifacts = json["artifacts"] as? [[String: Any]],
           let firstArtifact = artifacts.first,
           let parts = firstArtifact["parts"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return ToolResultBlock(
                toolUseId: toolUse.toolUseId, status: .success,
                content: [.text(text)]
            )
        }

        let text = String(data: responseData, encoding: .utf8) ?? ""
        return ToolResultBlock(
            toolUseId: toolUse.toolUseId, status: .success,
            content: [.text(text)]
        )
    }
}
