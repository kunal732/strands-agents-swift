/// A tool that can be invoked by an agent during the reasoning loop.
///
/// Tools receive structured input from the model and return a result.
/// They can also yield intermediate streaming events for progress reporting.
public protocol AgentTool: Sendable {
    /// Unique name for this tool. Must match `^[a-zA-Z0-9_-]{1,64}$`.
    var name: String { get }

    /// The specification describing this tool to the model.
    var toolSpec: ToolSpec { get }

    /// Execute the tool and stream results.
    ///
    /// The stream should yield zero or more `ToolStreamEvent` values for progress
    /// reporting, then complete. The final result is returned as a `ToolResultBlock`.
    ///
    /// - Parameters:
    ///   - toolUse: The tool invocation from the model, including input parameters.
    ///   - context: Execution context with access to the agent and invocation state.
    /// - Returns: The tool result.
    func call(
        toolUse: ToolUseBlock,
        context: ToolContext
    ) async throws -> ToolResultBlock
}

/// Events that a tool can emit during streaming execution.
public enum ToolStreamEvent: Sendable {
    /// A progress update (for UI display).
    case progress(String)
    /// An intermediate result.
    case intermediateResult(JSONValue)
}

// MARK: - Default Implementation

extension AgentTool {
    /// Default tool spec derived from the name.
    public var toolSpec: ToolSpec {
        ToolSpec(name: name, description: "", inputSchema: ["type": "object"])
    }
}
