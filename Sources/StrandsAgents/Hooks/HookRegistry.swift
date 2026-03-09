import Foundation

/// Dispatches strongly-typed hook events to registered callbacks.
///
/// Components register callbacks for specific event types. When an event is emitted,
/// all matching callbacks are invoked in registration order.
///
/// For cleanup events (like `AfterInvocationEvent`), use `invokeReversed` to run
/// callbacks in reverse registration order -- this ensures cleanup happens in the
/// opposite order of setup.
public final class HookRegistry: @unchecked Sendable {
    private var callbacks: [ObjectIdentifier: [AnyCallback]] = [:]
    private let lock = NSLock()

    public init() {}

    /// Register a callback for a specific event type.
    public func addCallback<E: HookEvent>(
        _ eventType: E.Type,
        _ callback: @escaping @Sendable (E) async throws -> Void
    ) {
        let key = ObjectIdentifier(eventType)
        let wrapped = AnyCallback { event in
            guard let typed = event as? E else { return }
            try await callback(typed)
        }
        lock.withLock {
            callbacks[key, default: []].append(wrapped)
        }
    }

    /// Invoke all callbacks registered for the given event's type in registration order.
    public func invoke<E: HookEvent>(_ event: E) async throws {
        let handlers = getHandlers(for: E.self)
        for handler in handlers {
            try await handler.invoke(event)
        }
    }

    /// Invoke all callbacks in reverse registration order.
    /// Use for cleanup events (e.g. `AfterInvocationEvent`) so teardown mirrors setup.
    public func invokeReversed<E: HookEvent>(_ event: E) async throws {
        let handlers = getHandlers(for: E.self)
        for handler in handlers.reversed() {
            try await handler.invoke(event)
        }
    }

    /// Register all hooks from a `HookProvider`.
    public func register(provider: any HookProvider) {
        provider.registerHooks(with: self)
    }

    /// Remove all registered callbacks.
    public func removeAll() {
        lock.withLock {
            callbacks.removeAll()
        }
    }

    /// Number of callbacks registered for a given event type.
    public func callbackCount<E: HookEvent>(for eventType: E.Type) -> Int {
        let key = ObjectIdentifier(eventType)
        return lock.withLock { callbacks[key]?.count ?? 0 }
    }

    // MARK: - Private

    private func getHandlers<E: HookEvent>(for eventType: E.Type) -> [AnyCallback] {
        let key = ObjectIdentifier(eventType)
        return lock.withLock { callbacks[key] ?? [] }
    }
}

// MARK: - Internal

private struct AnyCallback: Sendable {
    let invoke: @Sendable (any HookEvent) async throws -> Void

    init(invoke: @escaping @Sendable (any HookEvent) async throws -> Void) {
        self.invoke = invoke
    }
}
