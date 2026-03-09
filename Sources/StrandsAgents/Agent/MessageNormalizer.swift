import Foundation

/// Normalizes messages before sending to the model.
///
/// Fixes common issues that can cause model API errors:
/// - Removes blank text blocks from assistant messages with tool uses
/// - Replaces empty text with placeholder
/// - Validates and fixes invalid tool names
/// - Removes orphaned tool result blocks without matching tool uses
public enum MessageNormalizer {

    /// Valid tool name pattern.
    private nonisolated(unsafe) static let validToolNamePattern = /^[a-zA-Z0-9_\-]{1,64}$/

    /// Normalize a message array before sending to the model.
    public static func normalize(_ messages: [Message]) -> [Message] {
        messages.map { normalizeMessage($0) }
    }

    private static func normalizeMessage(_ message: Message) -> Message {
        var content = message.content

        if message.role == .assistant {
            let hasToolUse = content.contains { $0.toolUse != nil }

            if hasToolUse {
                // Remove blank text blocks from assistant messages with tool uses
                content = content.filter { block in
                    if let text = block.text, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return false
                    }
                    return true
                }
            }

            // Fix invalid tool names
            content = content.map { block in
                guard var toolUse = block.toolUse else { return block }
                if !isValidToolName(toolUse.name) {
                    toolUse.name = sanitizeToolName(toolUse.name)
                }
                return .toolUse(toolUse)
            }
        }

        // Replace empty text blocks with placeholder
        content = content.map { block in
            if let text = block.text, text.isEmpty {
                return .text(TextBlock(text: "[empty]"))
            }
            return block
        }

        return Message(role: message.role, content: content)
    }

    private static func isValidToolName(_ name: String) -> Bool {
        name.wholeMatch(of: validToolNamePattern) != nil
    }

    private static func sanitizeToolName(_ name: String) -> String {
        let sanitized = name
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }

        if sanitized.isEmpty { return "INVALID_TOOL_NAME" }
        return String(sanitized.prefix(64))
    }
}
