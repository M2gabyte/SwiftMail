import Foundation
import OSLog

private let logger = Logger(subsystem: "com.simplemail.app", category: "NetworkRetry")

/// Network retry utility with exponential backoff and jitter
enum NetworkRetry {

    /// Errors that are worth retrying
    static func isRetryable(_ error: Error) -> Bool {
        // URLError cases that are transient
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .notConnectedToInternet,
                 .secureConnectionFailed:
                return true
            default:
                return false
            }
        }

        // Check for HTTP 429 (rate limited) or 503 (service unavailable)
        // These are typically passed as custom errors
        return false
    }

    /// Execute an async operation with retry logic
    /// - Parameters:
    ///   - maxAttempts: Maximum number of attempts (default 3)
    ///   - baseDelay: Initial delay before first retry in seconds (default 1)
    ///   - maxDelay: Maximum delay between retries in seconds (default 30)
    ///   - operation: The async operation to execute
    /// - Returns: The result of the operation
    /// - Throws: The last error if all attempts fail
    static func withRetry<T>(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        var currentDelay = baseDelay

        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error

                // Don't retry on non-retryable errors
                guard isRetryable(error) else {
                    throw error
                }

                // Don't wait after the last attempt
                guard attempt < maxAttempts else {
                    break
                }

                // Calculate delay with exponential backoff and jitter
                let jitter = Double.random(in: 0.5...1.5)
                let delay = min(currentDelay * jitter, maxDelay)

                logger.info("Retry attempt \(attempt + 1)/\(maxAttempts) after \(String(format: "%.1f", delay))s delay")

                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // Exponential backoff
                currentDelay *= 2
            }
        }

        throw lastError ?? URLError(.unknown)
    }

    /// Execute a network request with retry logic
    /// - Parameters:
    ///   - request: The URLRequest to execute
    ///   - maxAttempts: Maximum number of attempts (default 3)
    /// - Returns: Tuple of (Data, URLResponse)
    /// - Throws: URLError or the last error if all attempts fail
    static func fetchWithRetry(
        _ request: URLRequest,
        maxAttempts: Int = 3
    ) async throws -> (Data, URLResponse) {
        return try await withRetry(maxAttempts: maxAttempts) {
            let (data, response) = try await URLSession.shared.data(for: request)

            // Check for HTTP error status codes that warrant retry
            if let httpResponse = response as? HTTPURLResponse {
                switch httpResponse.statusCode {
                case 429: // Rate limited
                    throw URLError(.resourceUnavailable)
                case 503: // Service unavailable
                    throw URLError(.cannotConnectToHost)
                case 504: // Gateway timeout
                    throw URLError(.timedOut)
                default:
                    break
                }
            }

            return (data, response)
        }
    }
}

// MARK: - Convenience Extensions

extension URLSession {
    /// Fetch data with automatic retry on transient failures
    func dataWithRetry(
        for request: URLRequest,
        maxAttempts: Int = 3
    ) async throws -> (Data, URLResponse) {
        return try await NetworkRetry.fetchWithRetry(request, maxAttempts: maxAttempts)
    }
}
