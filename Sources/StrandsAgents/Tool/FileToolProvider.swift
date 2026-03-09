import Foundation

/// A tool provider that loads tools from Swift source files at runtime.
///
/// Watches a directory for `.swift` files containing tool definitions.
/// Each file should define a struct/class conforming to `AgentTool`.
///
/// Since Swift doesn't support runtime compilation, this provider works with
/// **pre-compiled tool bundles** (`.bundle` or `.dylib` files) that export
/// tool factories.
///
/// For development, use `FileToolWatcher` to monitor a directory and
/// reload tools when files change.
///
/// ```swift
/// let watcher = FileToolWatcher(directory: URL(fileURLWithPath: "./tools"))
/// watcher.onChange = { tools in
///     for tool in tools {
///         agent.toolRegistry.register(tool)
///     }
/// }
/// watcher.start()
/// ```
public final class FileToolWatcher: @unchecked Sendable {
    private let directory: URL
    private let fileExtension: String
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "strands.tool-watcher")
    private var lastKnownFiles: Set<String> = []

    /// Called when tool files change. Provides the list of file URLs that changed.
    public var onChange: (([URL]) -> Void)?

    /// Create a file tool watcher.
    ///
    /// - Parameters:
    ///   - directory: Directory to watch for tool files.
    ///   - fileExtension: File extension to watch (default: "json" for tool schema files).
    public init(directory: URL, fileExtension: String = "json") {
        self.directory = directory
        self.fileExtension = fileExtension
    }

    deinit {
        stop()
    }

    /// Start watching for file changes.
    public func start() {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.checkForChanges()
        }

        source.setCancelHandler {
            close(fd)
        }

        // Initial scan
        lastKnownFiles = scanFiles()

        source.resume()
        self.source = source
    }

    /// Stop watching.
    public func stop() {
        source?.cancel()
        source = nil
    }

    /// Manually trigger a reload check.
    public func reload() {
        checkForChanges()
    }

    // MARK: - Private

    private func scanFiles() -> Set<String> {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return Set(files.filter { $0.hasSuffix(".\(fileExtension)") })
    }

    private func checkForChanges() {
        let currentFiles = scanFiles()
        let changedFiles = currentFiles.symmetricDifference(lastKnownFiles)

        if !changedFiles.isEmpty {
            lastKnownFiles = currentFiles
            let urls = currentFiles.map { directory.appendingPathComponent($0) }
            onChange?(urls)
        }
    }
}

/// A tool provider that loads tool definitions from JSON schema files.
///
/// Each JSON file describes a tool with `name`, `description`, and `inputSchema`.
/// The tool's execution is delegated to a handler closure.
///
/// ```swift
/// let provider = JSONSchemaToolProvider(
///     directory: URL(fileURLWithPath: "./tools"),
///     handler: { name, input, context in
///         // Dispatch to appropriate implementation
///         return "result"
///     }
/// )
/// ```
public struct JSONSchemaToolProvider: ToolProvider {
    private let directory: URL
    private let handler: @Sendable (String, JSONValue, ToolContext) async throws -> String

    public init(
        directory: URL,
        handler: @escaping @Sendable (String, JSONValue, ToolContext) async throws -> String
    ) {
        self.directory = directory
        self.handler = handler
    }

    public func loadTools() async throws -> [any AgentTool] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }

        return files
            .filter { $0.hasSuffix(".json") }
            .compactMap { filename -> (any AgentTool)? in
                let url = directory.appendingPathComponent(filename)
                guard let data = try? Data(contentsOf: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = json["name"] as? String
                else { return nil }

                let description = json["description"] as? String ?? ""
                let schema: JSONSchema
                if let schemaDict = json["inputSchema"] as? [String: Any],
                   let schemaData = try? JSONSerialization.data(withJSONObject: schemaDict),
                   let decoded = try? JSONDecoder().decode(JSONSchema.self, from: schemaData) {
                    schema = decoded
                } else {
                    schema = ["type": "object"]
                }

                let handler = self.handler
                return FunctionTool(name: name, description: description, inputSchema: schema) {
                    input, context in
                    try await handler(name, input, context)
                }
            }
    }
}
