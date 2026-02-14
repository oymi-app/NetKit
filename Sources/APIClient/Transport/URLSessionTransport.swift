import Foundation

/// A class that implements `HTTPTransport` using `URLSession`.
public class URLSessionTransport: HTTPTransport, @unchecked Sendable {

    /// The `URLSession` instance used to send HTTP requests.
    private let urlSession: URLSession

    /// Initializes a new instance of `URLSessionTransport` with a given `URLSession`.
    ///
    /// - Parameter urlSession: An optional `URLSession` instance to use. Defaults to `URLSession.shared`.
    public convenience init(sessionConfiguration: URLSessionConfiguration = .default) {
        self.init(urlSession: URLSession(configuration: sessionConfiguration))
    }

    /// Convenience initializer that creates a new instance of `URLSessionTransport` with a specific `URLSessionConfiguration`.
    ///
    /// - Parameter sessionConfiguration: The `URLSessionConfiguration` to use for the `URLSession`. Defaults to `.default`.
    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await urlSession.data(for: request)

        guard let res = response as? HTTPURLResponse else {
            throw APIClientError.transport(InternalTransportError.invalidResponse(response))
        }

        return (data, res)
    }

    public func bytes(request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, any Error>, HTTPURLResponse) {
        let (asyncBytes, response) = try await urlSession.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.transport(InternalTransportError.invalidResponse(response))
        }

        let stream = AsyncThrowingStream<UInt8, any Error> { continuation in
            let task = Task {
                do {
                    for try await byte in asyncBytes {
                        continuation.yield(byte)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }

        return (stream, httpResponse)
    }
}

extension HTTPURLResponse {
    public var isHTTP5xxError: Bool {
        (500...599).contains(statusCode)
    }
}

extension URLError {
    public var isPossiblyServerIssue: Bool {
        (code == .cannotConnectToHost || code == .networkConnectionLost || code == .secureConnectionFailed)
    }
}
