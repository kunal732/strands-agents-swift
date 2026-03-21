import Foundation

/// A tool provider that connects to a Model Context Protocol (MCP) server
/// and exposes its tools to the agent.
///
/// MCP servers communicate over stdin/stdout using JSON-RPC. This provider
/// launches the server process, discovers available tools, and proxies
/// tool calls to the server.
///
/// ```swift
/// let mcp = MCPToolProvider(
///     command: "npx",
///     arguments: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
/// )
///
/// let agent = Agent(model: provider)
/// try await agent.toolRegistry.loadFrom(mcp)
/// ```
public final class MCPToolProvider: ToolProvider, @unchecked Sendable {
    private let command: String
    private let arguments: [String]
    private let environment: [String: String]?
    private var process: Process?
    private var stdin: Pipe?
    private var stdout: Pipe?
    private let lock = NSLock()
    private var requestId = 0
    private var discoveredTools: [MCPToolProxy] = []

    /// Create an MCP tool provider.
    ///
    /// - Parameters:
    ///   - command: The command to launch the MCP server.
    ///   - arguments: Arguments for the command.
    ///   - environment: Optional environment variables for the process.
    public init(command: String, arguments: [String] = [], environment: [String: String]? = nil) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
    }

    deinit {
        process?.terminate()
    }

    // MARK: - ToolProvider

    public func loadTools() async throws -> [any AgentTool] {
        try await startServer()
        let toolList = try await listTools()
        discoveredTools = toolList
        return toolList
    }

    // MARK: - Server Lifecycle

    private func startServer() async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [command] + arguments

        if let env = environment {
            var processEnv = ProcessInfo.processInfo.environment
            for (key, value) in env { processEnv[key] = value }
            proc.environment = processEnv
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice

        try proc.run()

        self.process = proc
        self.stdin = stdinPipe
        self.stdout = stdoutPipe

        // Send initialize request
        let initResult = try await sendRequest(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": [
                "name": "strands-agents-swift",
                "version": "1.0.0",
            ],
        ])

        // Send initialized notification
        try sendNotification(method: "notifications/initialized", params: [:])

        _ = initResult
    }

    private func listTools() async throws -> [MCPToolProxy] {
        let result = try await sendRequest(method: "tools/list", params: [:])

        guard let tools = result["tools"] as? [[String: Any]] else {
            return []
        }

        return tools.compactMap { toolDict -> MCPToolProxy? in
            guard let name = toolDict["name"] as? String else { return nil }
            let description = toolDict["description"] as? String ?? ""
            let inputSchema = toolDict["inputSchema"] as? [String: Any] ?? ["type": "object"]

            return MCPToolProxy(
                name: name,
                spec: ToolSpec(
                    name: name,
                    description: description,
                    inputSchema: anyToJSONSchema(inputSchema)
                ),
                provider: self
            )
        }
    }

    // MARK: - Tool Execution

    func executeTool(name: String, arguments: JSONValue) async throws -> String {
        let args = jsonValueToAny(arguments)
        let result = try await sendRequest(method: "tools/call", params: [
            "name": name,
            "arguments": args,
        ])

        // Extract text content from result
        if let content = result["content"] as? [[String: Any]] {
            return content.compactMap { block -> String? in
                if block["type"] as? String == "text" {
                    return block["text"] as? String
                }
                return nil
            }.joined(separator: "\n")
        }

        return "\(result)"
    }

    // MARK: - JSON-RPC

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextRequestId()
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]

        let data = try JSONSerialization.data(withJSONObject: request)
        let message = data + Data([0x0A]) // newline delimiter

        guard let stdinPipe = stdin else {
            throw StrandsError.providerError(
                underlying: NSError(domain: "MCPToolProvider", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "MCP server not running"])
            )
        }

        stdinPipe.fileHandleForWriting.write(message)

        // Read response line-by-line until we get a JSON-RPC response matching our request ID
        guard let stdoutPipe = stdout else {
            throw StrandsError.providerError(
                underlying: NSError(domain: "MCPToolProvider", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "MCP server not running"])
            )
        }

        let json = try await readResponse(from: stdoutPipe, expectedId: id)

        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown MCP error"
            throw StrandsError.providerError(
                underlying: NSError(domain: "MCPToolProvider", code: error["code"] as? Int ?? -1,
                                    userInfo: [NSLocalizedDescriptionKey: message])
            )
        }

        return json["result"] as? [String: Any] ?? [:]
    }

    private func readResponse(from pipe: Pipe, expectedId: Int) async throws -> [String: Any] {
        let handle = pipe.fileHandleForReading
        var buffer = Data()

        // Read byte-by-byte until we find a newline-delimited JSON response
        // matching our request ID (skip notifications from the server)
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                // No data yet, yield and retry
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                continue
            }
            buffer.append(chunk)

            // Try to parse complete lines from the buffer
            while let newlineRange = buffer.range(of: Data([0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

                guard !lineData.isEmpty,
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                else { continue }

                // Skip notifications (no "id" field)
                guard let responseId = json["id"] as? Int else { continue }

                // Match our request
                if responseId == expectedId {
                    return json
                }
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]) throws {
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]

        let data = try JSONSerialization.data(withJSONObject: notification)
        stdin?.fileHandleForWriting.write(data + Data([0x0A]))
    }

    private func nextRequestId() -> Int {
        lock.withLock {
            requestId += 1
            return requestId
        }
    }

    // MARK: - Helpers

    private func anyToJSONSchema(_ dict: [String: Any]) -> JSONSchema {
        var result: JSONSchema = [:]
        for (key, value) in dict {
            result[key] = anyToJSONValue(value)
        }
        return result
    }

    private func anyToJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case let v as Bool: return .bool(v)
        case let v as Int: return .int(v)
        case let v as Double: return .double(v)
        case let v as String: return .string(v)
        case let v as [Any]: return .array(v.map { anyToJSONValue($0) })
        case let v as [String: Any]: return .object(v.mapValues { anyToJSONValue($0) })
        case is NSNull: return .null
        default: return .string("\(value)")
        }
    }

    private func jsonValueToAny(_ value: JSONValue) -> Any {
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

// MARK: - MCP Tool Proxy

/// A tool that proxies calls to an MCP server.
struct MCPToolProxy: AgentTool {
    let name: String
    let toolSpec: ToolSpec
    private let provider: MCPToolProvider

    init(name: String, spec: ToolSpec, provider: MCPToolProvider) {
        self.name = name
        self.toolSpec = spec
        self.provider = provider
    }

    func call(toolUse: ToolUseBlock, context: ToolContext) async throws -> ToolResultBlock {
        do {
            let result = try await provider.executeTool(name: name, arguments: toolUse.input)
            return ToolResultBlock(
                toolUseId: toolUse.toolUseId,
                status: .success,
                content: [.text(result)]
            )
        } catch {
            return ToolResultBlock(
                toolUseId: toolUse.toolUseId,
                status: .error,
                content: [.text("MCP error: \(error.localizedDescription)")]
            )
        }
    }
}
