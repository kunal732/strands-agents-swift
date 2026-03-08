/// A type that registers hook callbacks with the agent's hook registry.
///
/// Implement this protocol on conversation managers, session managers,
/// observability engines, or any component that needs to react to agent lifecycle events.
public protocol HookProvider: Sendable {
    func registerHooks(with registry: HookRegistry)
}
