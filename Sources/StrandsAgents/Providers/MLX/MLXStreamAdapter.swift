import Foundation
import MLXLMCommon
import Tokenizers

/// Converts between Strands types and MLX types.
enum MLXStreamAdapter {

    /// Build chat messages for the MLX UserInput format.
    ///
    /// MLX uses `[String: any Sendable]` dictionaries as its `Message` type.
    static func buildChatMessages(
        from messages: [StrandsAgents.Message],
        systemPrompt: String?
    ) -> [MLXLMCommon.Message] {
        var chatMessages: [MLXLMCommon.Message] = []

        if let system = systemPrompt {
            chatMessages.append(["role": "system", "content": system])
        }

        for message in messages {
            let role: String = message.role == .user ? "user" : "assistant"

            // Check for tool results in user messages
            let toolResults = message.toolResults
            if !toolResults.isEmpty {
                for result in toolResults {
                    let content = result.content.map { c -> String in
                        switch c {
                        case .text(let t): return t
                        case .json(let v): return "\(v)"
                        case .image, .document: return "[media]"
                        }
                    }.joined(separator: "\n")

                    chatMessages.append([
                        "role": "tool",
                        "name": "tool_response",
                        "content": content,
                    ])
                }
                continue
            }

            // Check for tool uses in assistant messages
            let toolUses = message.toolUses
            if !toolUses.isEmpty {
                // Build the assistant message with tool_calls
                var toolCalls: [[String: any Sendable]] = []
                for tu in toolUses {
                    let argsString: String
                    if let data = try? JSONEncoder().encode(tu.input),
                       let str = String(data: data, encoding: .utf8) {
                        argsString = str
                    } else {
                        argsString = "{}"
                    }

                    toolCalls.append([
                        "id": tu.toolUseId,
                        "type": "function",
                        "function": [
                            "name": tu.name,
                            "arguments": argsString,
                        ] as [String: any Sendable],
                    ])
                }

                var msg: MLXLMCommon.Message = [
                    "role": "assistant",
                    "tool_calls": toolCalls,
                ]
                let textContent = message.textContent
                if !textContent.isEmpty {
                    msg["content"] = textContent
                }
                chatMessages.append(msg)
                continue
            }

            // Plain text message
            let text = message.textContent
            if !text.isEmpty {
                chatMessages.append(["role": role, "content": text])
            }
        }

        return chatMessages
    }

    /// Convert Strands ToolSpecs to MLX ToolSpecs (OpenAI function calling format).
    ///
    /// MLX uses `[String: any Sendable]` dictionaries matching the OpenAI format:
    /// ```json
    /// {"type": "function", "function": {"name": "...", "description": "...", "parameters": {...}}}
    /// ```
    static func convertToolSpecs(_ specs: [StrandsAgents.ToolSpec]?) -> [Tokenizers.ToolSpec]? {
        guard let specs, !specs.isEmpty else { return nil }

        return specs.map { spec in
            // Convert JSONValue-based inputSchema to [String: any Sendable]
            let params = jsonValueToSendable(StrandsAgents.JSONValue.object(spec.inputSchema))

            return [
                "type": "function",
                "function": [
                    "name": spec.name,
                    "description": spec.description,
                    "parameters": params,
                ] as [String: any Sendable],
            ] as Tokenizers.ToolSpec
        }
    }

    /// Convert a JSONValue to a Foundation-compatible Sendable type.
    private static func jsonValueToSendable(_ value: StrandsAgents.JSONValue) -> any Sendable {
        switch value {
        case .null: return NSNull() as any Sendable
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let arr): return arr.map { jsonValueToSendable($0) }
        case .object(let dict): return dict.mapValues { jsonValueToSendable($0) }
        }
    }
}
