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
    
    public func bytes(request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let (bytes, response) = try await urlSession.bytes(for: request)

        guard let res = response as? HTTPURLResponse else {
            throw APIClientError.transport(InternalTransportError.invalidResponse(response))
        }

        return (bytes, res)
    }
}

public extension HTTPURLResponse {
    var isHTTP5xxError: Bool {
        (500 ... 599).contains(statusCode)
    }
}

public extension URLError {
    var isPossiblyServerIssue: Bool {
        (code == .cannotConnectToHost ||
         code == .networkConnectionLost ||
         code == .secureConnectionFailed)
    }
}
