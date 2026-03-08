/// A conversation manager that performs no management. Useful for testing or debugging.
public struct NullConversationManager: ConversationManager {
    public init() {}

    public func applyManagement(messages: inout [Message]) async {}

    public func reduceContext(messages: inout [Message], error: Error?) async throws {
        throw StrandsError.contextWindowOverflow
    }
}
