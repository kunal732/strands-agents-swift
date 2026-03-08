import Foundation

/// Dispatches strongly-typed hook events to registered callbacks.
///
/// Components register callbacks for specific event types. When an event is emitted,
/// all matching callbacks are invoked in registration order.
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

    /// Invoke all callbacks registered for the given event's type.
    public func invoke<E: HookEvent>(_ event: E) async throws {
        let key = ObjectIdentifier(E.self)
        let handlers: [AnyCallback] = lock.withLock {
            callbacks[key] ?? []
        }

        for handler in handlers {
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
}

// MARK: - Internal

private struct AnyCallback: Sendable {
    let invoke: @Sendable (any HookEvent) async throws -> Void

    init(invoke: @escaping @Sendable (any HookEvent) async throws -> Void) {
        self.invoke = invoke
    }
}
