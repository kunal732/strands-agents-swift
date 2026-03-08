import Foundation

/// Retry strategy with exponential backoff for model calls.
///
/// Applied around model invocations. Retries on `StrandsError.modelThrottled`.
public struct RetryStrategy: Sendable {
    public var maxAttempts: Int
    public var initialDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var backoffMultiplier: Double

    public init(
        maxAttempts: Int = 6,
        initialDelay: TimeInterval = 4.0,
        maxDelay: TimeInterval = 240.0,
        backoffMultiplier: Double = 2.0
    ) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.backoffMultiplier = backoffMultiplier
    }

    /// Execute an operation with retry logic.
    ///
    /// Only retries on `StrandsError.modelThrottled`. All other errors propagate immediately.
    public func execute<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        var delay = initialDelay

        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch let error as StrandsError {
                guard case .modelThrottled(let retryAfter) = error else {
                    throw error
                }
                lastError = error

                if attempt == maxAttempts {
                    break
                }

                let waitTime = retryAfter ?? delay
                try await Task.sleep(for: .seconds(waitTime))
                delay = min(delay * backoffMultiplier, maxDelay)
            } catch {
                throw error
            }
        }

        throw lastError ?? StrandsError.modelThrottled(retryAfter: nil)
    }
}
