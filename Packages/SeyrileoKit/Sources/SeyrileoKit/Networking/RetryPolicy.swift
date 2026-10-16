import Foundation

public typealias Sleeper = @Sendable (Duration) async throws -> Void

/// Bounded exponential backoff. Only errors classified as transient are retried; invalid
/// credentials, account problems, malformed responses and cancellation never are.
public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration

    public init(maxAttempts: Int = 3, baseDelay: Duration = .milliseconds(500), maxDelay: Duration = .seconds(4)) {
        precondition(maxAttempts >= 1)
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public static let none = RetryPolicy(maxAttempts: 1)

    /// Delay before retry number `retry` (1-based).
    public func delay(beforeRetry retry: Int) -> Duration {
        let multiplier = 1 << min(max(retry - 1, 0), 16)
        return min(baseDelay * multiplier, maxDelay)
    }

    public static let taskSleeper: Sleeper = { duration in try await Task.sleep(for: duration) }

    public func run<T: Sendable>(
        sleeper: Sleeper = RetryPolicy.taskSleeper,
        isTransient: @Sendable (Error) -> Bool,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch {
                guard attempt < maxAttempts, isTransient(error), !Task.isCancelled else { throw error }
                try await sleeper(delay(beforeRetry: attempt))
                attempt += 1
            }
        }
    }
}
