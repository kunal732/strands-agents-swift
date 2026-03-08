import Foundation

/// The role of a message participant.
public enum Role: String, Sendable, Codable, Hashable {
    case user
    case assistant
}

/// A single message in a conversation.
public struct Message: Sendable, Codable {
    public var role: Role
    public var content: [ContentBlock]

    public init(role: Role, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }
}

// MARK: - Convenience Initializers

extension Message {
    /// Create a user message with a single text block.
    public static func user(_ text: String) -> Message {
        Message(role: .user, content: [.text(TextBlock(text: text))])
    }

    /// Create an assistant message with a single text block.
    public static func assistant(_ text: String) -> Message {
        Message(role: .assistant, content: [.text(TextBlock(text: text))])
    }

    /// Create a user message from content blocks.
    public static func user(_ content: [ContentBlock]) -> Message {
        Message(role: .user, content: content)
    }

    /// Create an assistant message from content blocks.
    public static func assistant(_ content: [ContentBlock]) -> Message {
        Message(role: .assistant, content: content)
    }
}

// MARK: - Content Extraction

extension Message {
    /// Concatenated text from all text blocks in this message.
    public var textContent: String {
        content.compactMap(\.text).joined()
    }

    /// All tool use blocks in this message.
    public var toolUses: [ToolUseBlock] {
        content.compactMap(\.toolUse)
    }

    /// All tool result blocks in this message.
    public var toolResults: [ToolResultBlock] {
        content.compactMap(\.toolResult)
    }
}

/// The input a caller can pass to `Agent.run()` or `Agent.stream()`.
/// Supports strings, content blocks, or full message arrays.
public enum AgentInput: Sendable {
    case text(String)
    case contentBlocks([ContentBlock])
    case messages([Message])
}

extension AgentInput: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .text(value)
    }
}
