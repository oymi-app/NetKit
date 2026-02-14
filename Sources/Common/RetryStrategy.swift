import Foundation

/// A strategy for retrying network operations with specified intervals and a maximum retry count.
public struct RetryStrategy: Equatable, Sendable {

    /// Defines the interval for retrying a network operation.
    public enum RetryInterval: Equatable, Sendable {
        /// No retry, the operation does not retry on failure.
        case never

        /// A specific interval in seconds to wait before retrying.
        case seconds(TimeInterval)

        /// An incremental interval that doubles with each retry, starting from the initial value.
        case incremental(initial: TimeInterval)

        /// Creates an iterator that generates retry intervals.
        /// - Returns: An iterator that provides retry intervals, or `nil` if retries are not allowed.
        func makeIterator() -> AnyIterator<TimeInterval> {
            switch self {
            case .never:
                return AnyIterator {
                    nil
                }
            case let .seconds(duration):
                return AnyIterator {
                    duration
                }
            case let .incremental(initial):
                var currentDelay = initial
                return AnyIterator {
                    let delay = currentDelay
                    currentDelay *= 2
                    return delay
                }
            }
        }
    }

    /// The maximum number of times a network operation should be retried.
    public var maxRetryCount: Int

    /// The interval between retries, defined by the `RetryInterval` enum.
    public var retryInterval: RetryInterval

    /// Initializes a `RetryStrategy` with a maximum retry count and retry interval.
    /// - Parameters:
    ///   - maxRetryCount: The maximum number of retries.
    ///   - retryInterval: The interval between retries.
    public init(maxRetryCount: Int, retryInterval: RetryInterval) {
        self.maxRetryCount = maxRetryCount
        self.retryInterval = retryInterval
    }

    /// Creates an iterator that provides retry intervals based on the current strategy.
    /// - Returns: An iterator that generates retry intervals for a given strategy.
    public func makeDelayIterator() -> AnyIterator<TimeInterval> {
        let inner = retryInterval.makeIterator()

        return AnyIterator(inner)
    }

    /// A `RetryStrategy` with no retries.
    public static let noRetry = RetryStrategy(
        maxRetryCount: 0,
        retryInterval: .never
    )

    /// The default retry strategy with a default retry interval and max retry count.
    public static let `default` = RetryStrategy(
        maxRetryCount: Constants.maxRetryCount,
        retryInterval: defaultRetryInterval
    )

    /// Creates a custom `RetryStrategy` with a specified retry count and delay.
    /// - Parameters:
    ///   - count: The maximum number of retries.
    ///   - delay: The interval between retries in seconds.
    public static func retry(count: Int, delay: TimeInterval) -> RetryStrategy {
        return RetryStrategy(
            maxRetryCount: count,
            retryInterval: delay == 0 ? .never : .seconds(delay)
        )
    }

    /// Creates a custom `RetryStrategy` with incremental backoff.
    /// - Parameters:
    ///   - count: The maximum number of retries.
    ///   - initialDelay: The initial interval between retries in seconds.
    public static func incremental(count: Int, initialDelay: TimeInterval) -> RetryStrategy {
        return RetryStrategy(
            maxRetryCount: count,
            retryInterval: .incremental(initial: initialDelay)
        )
    }

    /// The default retry interval, set to 1 second.
    public static let defaultRetryInterval: RetryInterval = .seconds(1)  // 1 sec
}

extension RetryStrategy: Sequence {
    public struct Iterator: IteratorProtocol {
        var count: Int
        let interval: RetryInterval
        let intervalIterator: AnyIterator<TimeInterval>

        init(count: Int, interval: RetryInterval) {
            self.count = count
            self.interval = interval
            self.intervalIterator = interval.makeIterator()
        }

        /// Returns the next element in a ``ReversedTokenSequence``, i.e. the one
        /// that occurred before the current token in source order.
        public mutating func next() -> TimeInterval? {
            guard count > 0 else { return nil }
            count -= 1
            return intervalIterator.next()
        }
    }

    public func makeIterator() -> RetryStrategy.Iterator {
        Iterator(count: maxRetryCount, interval: retryInterval)
    }
}

private enum Constants: Sendable {

    /// The default maximum retry count
    static let maxRetryCount = 3
}
