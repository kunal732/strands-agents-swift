import Foundation
import StrandsAgents

/// Converts between Strands types and Anthropic API JSON.
enum AnthropicTypeConverter {

    // MARK: - Request Building

    static func buildRequestBody(
        messages: [Message],
        modelId: String,
        maxTokens: Int,
        systemPrompt: String?,
        toolSpecs: [ToolSpec]?,
        toolChoice: ToolChoice?,
        temperature: Double?,
        topP: Double?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": modelId,
            "max_tokens": maxTokens,
            "stream": true,
        ]

        if let system = systemPrompt {
            body["system"] = system
        }

        if let temp = temperature {
            body["temperature"] = temp
        }

        if let tp = topP {
            body["top_p"] = tp
        }

        body["messages"] = messages.map { convertMessage($0) }

        if let specs = toolSpecs, !specs.isEmpty {
            body["tools"] = specs.map { convertToolSpec($0) }

            if let choice = toolChoice {
                body["tool_choice"] = convertToolChoice(choice)
            }
        }

        return body
    }

    static func convertMessage(_ message: Message) -> [String: Any] {
        let role = message.role == .user ? "user" : "assistant"
        let content: Any = message.content.compactMap { convertContentBlock($0) }
        return ["role": role, "content": content]
    }

    static func convertContentBlock(_ block: ContentBlock) -> [String: Any]? {
        switch block {
        case .text(let tb):
            return ["type": "text", "text": tb.text]
        case .toolUse(let tu):
            return [
                "type": "tool_use",
                "id": tu.toolUseId,
                "name": tu.name,
                "input": jsonValueToAny(tu.input),
            ]
        case .toolResult(let tr):
            let content: [[String: Any]] = tr.content.compactMap { c in
                switch c {
                case .text(let t): return ["type": "text", "text": t]
                case .json(let v): return ["type": "text", "text": "\(jsonValueToAny(v))"]
                default: return nil
                }
            }
            return [
                "type": "tool_result",
                "tool_use_id": tr.toolUseId,
                "content": content,
                "is_error": tr.status == .error,
            ]
        case .image(let img):
            guard case .base64(let mediaType, let data) = img.source else { return nil }
            return [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mediaType,
                    "data": data,
                ],
            ]
        default:
            return nil
        }
    }

    static func convertToolSpec(_ spec: ToolSpec) -> [String: Any] {
        [
            "name": spec.name,
            "description": spec.description,
            "input_schema": jsonValueToAny(JSONValue.object(spec.inputSchema)),
        ]
    }

    static func convertToolChoice(_ choice: ToolChoice) -> [String: Any] {
        switch choice {
        case .auto: return ["type": "auto"]
        case .any: return ["type": "any"]
        case .tool(let name): return ["type": "tool", "name": name]
        case .none: return ["type": "auto"]
        }
    }

    // MARK: - SSE Event Parsing

    /// Parse a server-sent event data line into a ModelStreamEvent.
    static func parseStreamEvent(
        eventType: String,
        data: [String: Any]
    ) -> ModelStreamEvent? {
        switch eventType {
        case "message_start":
            return .messageStart(role: .assistant)

        case "content_block_start":
            guard let contentBlock = data["content_block"] as? [String: Any] else { return nil }
            let type = contentBlock["type"] as? String
            if type == "tool_use" {
                let id = contentBlock["id"] as? String ?? ""
                let name = contentBlock["name"] as? String ?? ""
                return .contentBlockStart(ContentBlockStartData(
                    toolUse: ToolUseStart(toolUseId: id, name: name)
                ))
            }
            return .contentBlockStart(ContentBlockStartData())

        case "content_block_delta":
            guard let delta = data["delta"] as? [String: Any] else { return nil }
            let type = delta["type"] as? String
            switch type {
            case "text_delta":
                let text = delta["text"] as? String ?? ""
                return .contentBlockDelta(.text(text))
            case "input_json_delta":
                let json = delta["partial_json"] as? String ?? ""
                return .contentBlockDelta(.toolUseInput(json))
            case "thinking_delta":
                let text = delta["thinking"] as? String
                return .contentBlockDelta(.reasoning(text: text, signature: nil))
            case "signature_delta":
                let sig = delta["signature"] as? String
                return .contentBlockDelta(.reasoning(text: nil, signature: sig))
            default:
                return nil
            }

        case "content_block_stop":
            return .contentBlockStop

        case "message_delta":
            guard let delta = data["delta"] as? [String: Any] else { return nil }
            let stopReason = delta["stop_reason"] as? String
            let reason = parseStopReason(stopReason)

            // Also extract usage from message_delta
            var usage: Usage?
            if let usageDict = data["usage"] as? [String: Any] {
                usage = parseUsage(usageDict)
            }

            // Return messageStop; usage will come with metadata
            if let usage {
                return .metadata(usage: usage, metrics: nil)
            }
            return .messageStop(stopReason: reason)

        case "message_stop":
            return nil // Already handled by message_delta

        case "ping":
            return nil

        default:
            return nil
        }
    }

    static func parseStopReason(_ reason: String?) -> StopReason {
        switch reason {
        case "end_turn": return .endTurn
        case "tool_use": return .toolUse
        case "max_tokens": return .maxTokens
        case "stop_sequence": return .stopSequence
        default: return .endTurn
        }
    }

    static func parseUsage(_ dict: [String: Any]) -> Usage {
        Usage(
            inputTokens: dict["input_tokens"] as? Int ?? 0,
            outputTokens: dict["output_tokens"] as? Int ?? 0,
            totalTokens: (dict["input_tokens"] as? Int ?? 0) + (dict["output_tokens"] as? Int ?? 0),
            cacheReadInputTokens: dict["cache_read_input_tokens"] as? Int,
            cacheWriteInputTokens: dict["cache_creation_input_tokens"] as? Int
        )
    }

    // MARK: - Helpers

    static func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let arr): return arr.map { jsonValueToAny($0) }
        case .object(let dict): return dict.mapValues { jsonValueToAny($0) }
        }
    }
}
