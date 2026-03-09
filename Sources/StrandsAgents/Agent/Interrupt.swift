import Foundation

/// An interrupt that pauses agent execution and requests human input.
///
/// Tools or hooks can throw an `InterruptError` to pause the agent loop.
/// The caller can then provide a response and resume execution.
///
/// ```swift
/// // In a tool:
/// func call(toolUse: ToolUseBlock, context: ToolContext) async throws -> ToolResultBlock {
///     throw InterruptError(
///         name: "approve_action",
///         reason: "About to delete 50 files. Continue?",
///         toolUseId: toolUse.toolUseId
///     )
/// }
///
/// // In the caller:
/// do {
///     let result = try await agent.run("Clean up old files")
/// } catch let interrupt as InterruptError {
///     print("Agent paused: \(interrupt.reason)")
///     // Resume with approval
///     let result = try await agent.resume(
///         interruptResponse: InterruptResponse(
///             name: interrupt.name,
///             response: "yes, proceed"
///         )
///     )
/// }
/// ```
public struct InterruptError: Error, Sendable {
    /// Identifier for this interrupt type.
    public let name: String

    /// Human-readable reason for the interrupt.
    public let reason: String

    /// The tool use ID that triggered the interrupt, if any.
    public let toolUseId: String?

    public init(name: String, reason: String, toolUseId: String? = nil) {
        self.name = name
        self.reason = reason
        self.toolUseId = toolUseId
    }
}

/// A response to an interrupt, provided by the human.
public struct InterruptResponse: Sendable {
    /// The interrupt name this responds to.
    public let name: String

    /// The human's response.
    public let response: String

    public init(name: String, response: String) {
        self.name = name
        self.response = response
    }
}
