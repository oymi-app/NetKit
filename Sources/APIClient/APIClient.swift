import Foundation

/// Protocol defining the contract for an API client.
///
/// The `APIClientProtocol` defines methods for making HTTP requests to API endpoints.
public protocol APIClientProtocol: AnyObject, Sendable {

    /// Requests data from a specified endpoint and decodes the response.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint to request data from.
    /// - Returns: A `Response` containing the decoded data of type `T`.
    /// - Throws: An `APIClientError` if the request or decoding fails.
    @discardableResult
    func request<T: Decodable & Sendable>(_ endpoint: any Endpoint) async throws(APIClientError) -> Response<T>

    /// Requests data from a specified endpoint without a specific expected response.
    ///
    /// This method is used for requests that don't return data.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint to request data from.
    /// - Returns: A `Response` with no additional data.
    /// - Throws: An `APIClientError` if the request fails.
    @discardableResult
    func request(_ endpoint: any Endpoint) async throws(APIClientError) -> Response<Void>

    /// Requests data from a specified endpoint with progress tracking and decodes the response.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint to request data from.
    ///   - progress: A closure that is called periodically with the progress of the request.
    /// - Returns: A `Response` containing the decoded data of type `T`.
    /// - Throws: An `APIClientError` if the request or decoding fails.
    @discardableResult
    func request<T: Decodable & Sendable>(
        _ endpoint: any Endpoint,
        with progress: @escaping @Sendable (Double) -> Void
    ) async throws(APIClientError) -> Response<T>
}

/// An implementation of `APIClientProtocol`.
///
/// The `APIClient` manages network operations with support for request/response
/// middleware, customizable HTTP transport, and optional verbose logging.
public final class APIClient: APIClientProtocol {

    /// Configuration settings for the API client.
    private let configuration: Configuration

    /// Middleware to be applied to requests before they are sent.
    private let requestMiddlewares: [any RequestMiddleware]

    /// Middleware to be applied to responses before they are decoded.
    private let responseMiddlewares: [any ResponseMiddleware]

    /// The HTTP transport used to send requests.
    private let transport: HTTPTransport

    @inline(__always)
    private var decoder: JSONDecoder { configuration.makeDecoder() }

    /// Initializes a new instance of `APIClient`.
    ///
    /// - Parameters:
    ///   - configuration: The `Configuration` object containing base URL, encoders, and other settings.
    ///   - requestMiddlewares: Middleware to modify requests before sending.
    ///   - responseMiddlewares: Middleware to process raw responses before decoding.
    ///   - transport: The `HTTPTransport` instance for sending requests (default: `URLSessionTransport`).
    public init(
        configuration: Configuration,
        requestMiddlewares: [any RequestMiddleware] = [],
        responseMiddlewares: [any ResponseMiddleware] = [],
        transport: HTTPTransport = URLSessionTransport(urlSession: .shared)
    ) {
        self.configuration = configuration
        self.transport = transport

        // When verbose, prepend internal logging middleware
        if configuration.verbose {
            self.requestMiddlewares = [LoggingRequestMiddleware()] + requestMiddlewares
            self.responseMiddlewares = responseMiddlewares + [LoggingResponseMiddleware()]
        } else {
            self.requestMiddlewares = requestMiddlewares
            self.responseMiddlewares = responseMiddlewares
        }
    }

    // MARK: - Public API

    @discardableResult
    public func request<T: Decodable & Sendable>(_ endpoint: any Endpoint) async throws(APIClientError) -> Response<T> {
        let response = try await execute(endpoint: endpoint)
        return try await decodeResponse(response)
    }

    @discardableResult
    public func request(_ endpoint: any Endpoint) async throws(APIClientError) -> Response<Void> {
        let response = try await execute(endpoint: endpoint)
        return response.map { _ in }
    }

    @discardableResult
    public func request<T: Decodable & Sendable>(
        _ endpoint: any Endpoint,
        with progress: @escaping @Sendable (Double) -> Void
    ) async throws(APIClientError) -> Response<T> {
        let response = try await execute(endpoint: endpoint, progress: progress)
        return try await decodeResponse(response)
    }

    // MARK: - Pipeline

    /// Shared execution pipeline: build operation → send → apply response middleware → check status.
    private func execute(
        endpoint: any Endpoint,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws(APIClientError) -> Response<Data> {
        let middlewareClosure: NetworkOperation.Middleware = {
            [requestMiddlewares] request, endpoint throws(APIClientError) in
            for middleware in requestMiddlewares {
                do {
                    try await middleware.makeUp(request: &request, for: endpoint)
                } catch let error as APIClientError {
                    throw error
                } catch {
                    throw APIClientError.requestError(error)
                }
            }
        }

        let operation: NetworkOperation
        if let progress {
            operation = UploadNetworkOperation(
                configuration: configuration,
                requestMiddleware: middlewareClosure,
                transport: transport,
                endpoint: endpoint,
                retryStrategy: endpoint.retryStrategy,
                progressHandler: progress
            )
        } else {
            operation = NetworkOperation(
                configuration: configuration,
                requestMiddleware: middlewareClosure,
                transport: transport,
                endpoint: endpoint,
                retryStrategy: endpoint.retryStrategy
            )
        }

        // Send request
        var response = try await operation.startRequest()

        // Apply response middlewares
        for middleware in responseMiddlewares {
            response = try await middleware.modify(response: response, for: endpoint)
        }

        // Check HTTP status
        if let error = makeError(from: response.data, response: response.response) {
            throw error
        }

        return response
    }

    // MARK: - Decoding

    private func decodeResponse<T: Decodable & Sendable>(
        _ response: Response<Data>
    ) async throws(APIClientError) -> Response<T> {
        let value: T = try decodeValue(from: response.data, decoder: decoder)
        return Response(value: value, data: response.data, response: response.response)
    }

    /// Decodes raw data into a specified Decodable type.
    ///
    /// Handles special cases: empty data for optionals, `Data` type, `String` type,
    /// empty JSON `{}` for optionals.
    private func decodeValue<T: Decodable & Sendable>(from data: Data, decoder: JSONDecoder) throws(APIClientError) -> T
    {
        if data.isEmpty, T.self is OptionalDecoding.Type {
            return Optional<Decodable>.none as! T
        }

        if T.self == Data.self {
            return data as! T
        }

        if T.self == String.self {
            guard let string = String(data: data, encoding: .utf8) else {
                throw APIClientError.networkError(URLError(.badServerResponse))
            }
            return string as! T
        }

        // Check special case when backend returns empty json "{}"
        if T.self is OptionalDecoding.Type,
            data.count == 2, data.contains([0x7b, 0x7d])
        {
            return Optional<Decodable>.none as! T
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIClientError.decoderError(error)
        }
    }

    // MARK: - Error Handling

    /// Determines the appropriate error based on HTTP status code.
    private func makeError(from data: Data?, response: URLResponse?) -> APIClientError? {
        guard let response = response as? HTTPURLResponse else {
            return nil
        }

        if (200...299).contains(response.statusCode) {
            return nil
        }

        if let data, let error = try? decoder.decode(ErrorResponse.self, from: data) {
            return .responseError(response, error)
        }

        return .responseError(response, nil)
    }
}

// MARK: - Configuration

/// A structure representing the configuration for an API client.
///
/// The `Configuration` struct stores the base URL, encoding/decoding strategies,
/// timeout, headers, and other settings for HTTP requests.
public struct Configuration: Sendable {

    /// The base URL for all API requests.
    public let baseURL: URL

    /// The timeout interval for requests, in seconds.
    public let timeoutInterval: TimeInterval

    /// Default HTTP headers applied to every request.
    public let defaultHeaders: [String: String]

    /// The cache policy for requests.
    public let cachePolicy: URLRequest.CachePolicy

    /// The date decoding strategy for JSON responses.
    public let dateDecodingStrategy: JSONDecoder.DateDecodingStrategy

    /// The date encoding strategy for JSON requests.
    public let dateEncodingStrategy: JSONEncoder.DateEncodingStrategy

    /// Whether to enable verbose logging of requests and responses.
    public let verbose: Bool

    /// Creates a new JSON decoder with the configured strategies.
    public func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateDecodingStrategy
        return decoder
    }

    /// Creates a new JSON encoder with the configured strategies.
    public func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = dateEncodingStrategy
        return encoder
    }

    /// Initializes a new instance of `Configuration`.
    ///
    /// - Parameters:
    ///   - baseURL: The base URL for API requests. Required.
    ///   - timeoutInterval: Request timeout in seconds. Default: 30.
    ///   - defaultHeaders: Default headers applied to every request. Default: empty.
    ///   - cachePolicy: Cache policy for requests. Default: `.useProtocolCachePolicy`.
    ///   - dateDecodingStrategy: Strategy for decoding dates. Default: `.secondsSince1970`.
    ///   - dateEncodingStrategy: Strategy for encoding dates. Default: `.secondsSince1970`.
    ///   - verbose: Enable verbose request/response logging. Default: `false`.
    public init(
        baseURL: URL,
        timeoutInterval: TimeInterval = 30,
        defaultHeaders: [String: String] = [:],
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .secondsSince1970,
        dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .secondsSince1970,
        verbose: Bool = false
    ) {
        self.baseURL = baseURL
        self.timeoutInterval = timeoutInterval
        self.defaultHeaders = defaultHeaders
        self.cachePolicy = cachePolicy
        self.dateDecodingStrategy = dateDecodingStrategy
        self.dateEncodingStrategy = dateEncodingStrategy
        self.verbose = verbose
    }
}

// MARK: - Internal Logging Middleware

/// Logs outgoing requests as curl commands when verbose mode is enabled.
struct LoggingRequestMiddleware: RequestMiddleware {
    func makeUp(request: inout URLRequest, for endpoint: any Endpoint) async throws {
        log(message: "⬆️ \(request.curlString)")
    }
}

/// Logs incoming responses when verbose mode is enabled.
struct LoggingResponseMiddleware: ResponseMiddleware {
    func modify(response: Response<Data>, for endpoint: any Endpoint) async throws(APIClientError) -> Response<Data> {
        let responseBody = String(bytes: response.data, encoding: .utf8)
        log(message: "⬇️ [\(response.statusCode ?? 0)] \(responseBody ?? "Empty response")")
        return response
    }
}

// MARK: - Helpers

public protocol OptionalDecoding {}
extension Optional: OptionalDecoding {}
