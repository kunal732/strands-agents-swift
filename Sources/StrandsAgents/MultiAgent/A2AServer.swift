import Foundation

/// Exposes an Agent as an Agent-to-Agent (A2A) compatible HTTP service.
///
/// Implements the A2A protocol for inter-agent communication over HTTP.
/// Other agents can discover this agent's capabilities and send tasks.
///
/// ```swift
/// let agent = Agent(model: provider, tools: [MyTool()])
/// let server = A2AServer(agent: agent, name: "Research Agent", port: 8080)
/// try await server.start()
/// ```
///
/// ## Protocol
///
/// The server exposes these endpoints:
/// - `GET /.well-known/agent.json` -- Agent card (capabilities, skills)
/// - `POST /tasks/send` -- Submit a task (synchronous)
/// - `POST /tasks/sendSubscribe` -- Submit a task with streaming
public final class A2AServer: @unchecked Sendable {
    private let agent: Agent
    private let name: String
    private let description: String
    private let version: String
    private let host: String
    private let port: UInt16
    private var listener: Task<Void, Error>?

    public init(
        agent: Agent,
        name: String = "Strands Agent",
        description: String = "A Strands SDK agent exposed via A2A protocol",
        version: String = "1.0.0",
        host: String = "localhost",
        port: UInt16 = 8080
    ) {
        self.agent = agent
        self.name = name
        self.description = description
        self.version = version
        self.host = host
        self.port = port
    }

    /// Generate the agent card describing this agent's capabilities.
    public func agentCard() -> [String: Any] {
        let skills: [[String: Any]] = agent.toolNames.map { name in
            ["id": name, "name": name]
        }

        return [
            "name": name,
            "description": description,
            "url": "http://\(host):\(port)",
            "version": version,
            "capabilities": [
                "streaming": true,
                "pushNotifications": false,
            ] as [String: Any],
            "skills": skills,
        ]
    }

    /// Handle an incoming A2A task request.
    ///
    /// Converts the A2A message parts to Strands content blocks,
    /// runs the agent, and returns the result as A2A artifacts.
    public func handleTask(input: [String: Any]) async throws -> [String: Any] {
        // Extract text from A2A message parts
        let message = input["message"] as? [String: Any] ?? [:]
        let parts = message["parts"] as? [[String: Any]] ?? []

        let textParts = parts.compactMap { part -> String? in
            if part["type"] as? String == "text" {
                return part["text"] as? String
            }
            return nil
        }

        let prompt = textParts.joined(separator: "\n")

        // Run the agent
        let result = try await agent.run(prompt)

        // Convert result to A2A format
        let responseParts: [[String: Any]] = [
            ["type": "text", "text": result.message.textContent],
        ]

        return [
            "id": UUID().uuidString,
            "status": ["state": "completed"],
            "artifacts": [
                [
                    "parts": responseParts,
                    "metadata": [
                        "stopReason": result.stopReason.rawValue,
                        "inputTokens": result.usage.inputTokens,
                        "outputTokens": result.usage.outputTokens,
                    ] as [String: Any],
                ],
            ],
        ]
    }

    /// Handle an A2A task with streaming response.
    public func handleTaskStreaming(
        input: [String: Any],
        yield: @escaping @Sendable ([String: Any]) async -> Void
    ) async throws {
        let message = input["message"] as? [String: Any] ?? [:]
        let parts = message["parts"] as? [[String: Any]] ?? []
        let prompt = parts.compactMap { ($0["type"] as? String == "text") ? $0["text"] as? String : nil }
            .joined(separator: "\n")

        for try await event in agent.stream(prompt) {
            switch event {
            case .textDelta(let text):
                await yield([
                    "type": "artifact.update",
                    "artifact": ["parts": [["type": "text", "text": text]]],
                ])
            case .result(let result):
                await yield([
                    "type": "task.completed",
                    "status": ["state": "completed"],
                    "artifact": [
                        "parts": [["type": "text", "text": result.message.textContent]],
                        "metadata": [
                            "stopReason": result.stopReason.rawValue,
                            "inputTokens": result.usage.inputTokens,
                            "outputTokens": result.usage.outputTokens,
                        ],
                    ],
                ])
            default:
                break
            }
        }
    }
}
