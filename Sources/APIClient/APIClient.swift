import Foundation

/// Protocol defining the contract for an API client.
///
/// The `APIClient` protocol defines methods for making HTTP requests to API endpoints.
public protocol APIClientProtocol: AnyObject, Sendable {

    /// Requests data from a specified endpoint and decodes the response.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint to request data from.
    /// - Returns: A `Response` containing the decoded data of type `T`.
    /// - Throws: An error if the request or decoding fails.
    @discardableResult
    func request<T: Decodable>(_ endpoint: Endpoint) async throws(APIClientError) -> Response<T>

    /// Requests data from a specified endpoint without a specific expected response.
    ///
    /// This method is used for requests that don't return data.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint to request data from.
    /// - Returns: A `Response` with no additional data.
    /// - Throws: An error if the request fails.
    @discardableResult
    func request(_ endpoint: Endpoint) async throws(APIClientError) -> Response<Void>

    /// Requests data from a specified endpoint with progress tracking and decodes the response.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint to request data from.
    ///   - progress: A closure that is called periodically with the progress of the request.
    /// - Returns: A `Response` containing the decoded data of type `T`.
    /// - Throws: An error if the request or decoding fails.
    @discardableResult
    func request<T: Decodable>(_ endpoint: any Endpoint, with progress: @escaping @Sendable (Double) -> Void) async throws(APIClientError) -> Response<T>
}

/// An actor representing a Pure API client.
///
/// The `APIClient` class is an implementation of the `APIClientProtocol` protocol,
/// designed to manage network operations with support for authentication and
/// customizable HTTP transport. It uses a configuration object to set up its
/// base URL, JSON encoder/decoder, and other related settings.
public final class APIClient: APIClientProtocol {

    /// Configuration settings for the API client.
    private let configuration: Configuration

    /// Middleware to do auth
    private let authMiddleware: AuthMiddleware?

    /// Middleware to be applied to requests before they are sent.
    private let requestMiddlewares: [RequestMiddleware]

    /// Middleware to be applied to responses after they are received.
    private let responseMiddlewares: [any ResponseMiddleware]

    /// The HTTP transport used to send requests.
    private let transport: HTTPTransport

    @inline(__always)
    private var decoder: JSONDecoder { configuration.makeDecoder() }

    /// Initializes a new instance of `APIClient` with a base URL, authentication, and transport.
    ///
    /// - Parameters:
    ///   - baseURL: The base URL for the API client.
    ///   - transport: The `HTTPTransport` instance for sending requests (default: `URLSessionTransport`).
    public convenience init(
        authMiddleware: AuthMiddleware?,
        requestMiddleware: [RequestMiddleware] = [],
        responseMiddlewares: [any ResponseMiddleware] = [],
        transport: HTTPTransport = URLSessionTransport(urlSession: .shared)
    ) {
        let configuration = Configuration()
        self.init(configuration: configuration,
                  authMiddleware: authMiddleware,
                  requestMiddleware: requestMiddleware,
                  responseMiddlewares: responseMiddlewares,
                  transport: transport)
    }

    /// Initializes a new instance of `APIClient` with a custom configuration.
    ///
    /// - Parameters:
    ///   - configuration: The `Configuration` object containing settings like base URL and encoders.
    ///   - transport: The `HTTPTransport` instance for sending requests (default: `URLSessionTransport`).
    public init(
        configuration: Configuration,
        authMiddleware: AuthMiddleware?,
        requestMiddleware: [RequestMiddleware],
        responseMiddlewares: [any ResponseMiddleware],
        transport: HTTPTransport = URLSessionTransport(urlSession: .shared)
    ) {
        self.configuration = configuration
        self.authMiddleware = authMiddleware
        self.requestMiddlewares = requestMiddleware
        self.responseMiddlewares = responseMiddlewares
        self.transport = transport
    }

    @discardableResult
    public func request<T: Decodable>(_ endpoint: any Endpoint) async throws(APIClientError) -> Response<T> where T: Sendable {
        let response: Response<Data> = try await request(endpoint, forcingTokenRefresh: false)
        return try await handleNetworkOperationResponse(response.response,
                                                        data: response.data)
    }

    @discardableResult
    public func request(_ endpoint: any Endpoint) async throws(APIClientError) -> Response<Void> {
        let response: Response<Data> = try await request(endpoint, forcingTokenRefresh: false)
        return response.map { _ in }
    }

    private func request(_ endpoint: any Endpoint, forcingTokenRefresh: Bool) async throws(APIClientError) -> Response<Data> {
        let operation = makeOperation(from: endpoint, middleware: { [authMiddleware, requestMiddlewares] request, endpoint throws(APIClientError) in
            if endpoint.isAuthorizationNeeded {
                do {
                    try await authMiddleware?.auth(request: &request, for: endpoint, force: forcingTokenRefresh)
                } catch let error as APIClientError {
                    throw error
                } catch {
                    throw APIClientError.requestError(error)
                }
            }

            for middleware in requestMiddlewares {
                do {
                    try await middleware.makeUp(request: &request, for: endpoint)
                } catch {
                    throw APIClientError.requestError(error)
                }
            }
        })

        let checkingAuthErrors = endpoint.isAuthorizationNeeded && !forcingTokenRefresh

        return try await request(endpoint,
                                 networkOperation: operation,
                                 checkingAuthErrors: checkingAuthErrors)
    }

    private func request(_ endpoint: any Endpoint,
                         networkOperation: NetworkOperation,
                         checkingAuthErrors: Bool) async throws(APIClientError) -> Response<Data> {
        do throws(APIClientError) {
            let response = try await networkOperation.startRequest()

            guard let error = makeError(from: response.data, response: response.response) else {
                return response
            }

            // If we receive unauthorizedError, try to make a request again, but forcing token refresh
            if checkingAuthErrors && error.isUnauthorizedError {
                return try await request(endpoint, forcingTokenRefresh: true)
            } else {
                // Notify middlewares
                let errorToThrow = await handleAuthError(error, for: endpoint)
                handle(error: error, response: response.response)

                throw errorToThrow
            }
        } catch {
            // Notify middlewares
            let errorToThrow = await handleAuthError(error, for: endpoint)
            handle(error: error)

            throw errorToThrow
        }
    }

    private func handleAuthError(_ error: APIClientError, for endpoint: any Endpoint) async -> APIClientError {
        var errorToReturn = error

        if let authMiddleware, endpoint.isAuthorizationNeeded {
            do {
                try await authMiddleware.handle(error: error)
            } catch let error as APIClientError {
                errorToReturn = error
            } catch {
                // NOP
            }
        }

        return errorToReturn
    }
}

public extension APIClient {
    @discardableResult
    func request<T: Decodable>(_ endpoint: any Endpoint,
                               with progress: @escaping @Sendable (Double) -> Void
    ) async throws(APIClientError) -> Response<T> {
        let operation = makeOperationWithProgress(from: endpoint, middleware: { [authMiddleware, requestMiddlewares] request, endpoint in

            if endpoint.isAuthorizationNeeded {
                try? await authMiddleware?.auth(request: &request, for: endpoint, force: false)
            }

            for middleware in requestMiddlewares {
                try? await middleware.makeUp(request: &request, for: endpoint)
            }
        }, progress: progress)

        let response = try await operation.startRequest()
        return try await handleNetworkOperationResponse(response.response,
                                                        data: response.data)
    }
}

public extension APIClient {
    private func handle<T>(response: Response<T>) {
        for middleware in responseMiddlewares {
            middleware.handle(response: response)
        }
    }

    private func handle(error: APIClientError) {
        let middlewares = responseMiddlewares

        for middleware in middlewares {
            middleware.handle(error: error)
        }
    }

    private func handle(error: APIClientError, response: HTTPURLResponse) {
        let middlewares = responseMiddlewares

        for middleware in middlewares {
            middleware.handle(error: error, response: response)
        }
    }
}

private extension APIClient {
    /// Handles the response from a network operation and decodes the data.
    ///
    /// The `handleNetworkOperationResponse` method attempts to decode the response data into a specified type. If the data
    /// is empty or decoding fails, appropriate errors are thrown.
    ///
    /// - Parameters:
    ///   - response: The `HTTPURLResponse` received from the network operation.
    ///   - data: The raw data received from the response.
    /// - Returns: A `Response<T>` containing the decoded data and the HTTP response.
    /// - Throws:
    ///   - `APIError.networkError`: If the response data is empty, indicating a bad server response.
    ///   - `APIError.decoderError`: If there's an error decoding the response data.
    func handleNetworkOperationResponse<T: Decodable>(_ response: HTTPURLResponse, data: Data) async throws(APIClientError) -> Response<T> {
        let value: T = try await decodeValue(from: data, decoder: decoder)
        let response = Response(value: value, data: data, response: response)

        // Notify middlewares
        handle(response: response)

        return response
    }

    /// Creates a `NetworkOperation` instance for the specified endpoint.
    ///
    /// - Parameter endpoint: The `Endpoint` from which to create the network operation.
    /// - Returns: A new `NetworkOperation` instance configured with the given endpoint and current settings.
    // TODO: update docs
    func makeOperation(from endpoint: any Endpoint,
                       middleware: @escaping NetworkOperation.Middleware) -> NetworkOperation {
        NetworkOperation(requestMiddleware: middleware,
                         transport: transport,
                         endpoint: endpoint,
                         retryStrategy: endpoint.retryStrategy)
    }

    /// Creates a `UploadNetworkOperation` instance for the specified endpoint.
    ///
    /// - Parameter
    ///     - endpoint: The `Endpoint` from which to create the network operation.
    ///     - progress: Progress block handler
    /// - Returns: A new `NetworkOperation` instance configured with the given endpoint and current settings.
    // TODO: update docs
    func makeOperationWithProgress(from endpoint: any Endpoint,
                                   middleware: @escaping NetworkOperation.Middleware,
                                   progress: @escaping @Sendable (Double) -> Void) -> NetworkOperation {
        UploadNetworkOperation(requestMiddleware: middleware,
                               transport: transport,
                               endpoint: endpoint,
                               retryStrategy: endpoint.retryStrategy,
                               progressHandler: progress)
    }

    /// Determines the appropriate error type based on HTTP response and data.
    ///
    /// The `makeError` function examines the HTTP response status code and,
    /// if it's not in the 200-299 range, tries to extract error details from the
    /// response data. If it successfully decodes an `ErrorResponse`, it creates
    /// an error with detailed information. If no specific error information is
    /// found, a generic response error is returned.
    ///
    /// - Parameters:
    ///   - data: The raw data received from the HTTP response, potentially containing error details.
    ///   - response: The `URLResponse` to check for HTTP status and type.
    /// - Returns: An `Error?` indicating the specific error if one is found; otherwise, returns `nil`.
    func makeError(from data: Data?, response: URLResponse?) -> APIClientError? {
        if let response = response as? HTTPURLResponse {
            if (200...299).contains(response.statusCode) {
                return nil
            } else if let data = data, let error = try? decoder.decode(ErrorResponse.self, from: data) {
                return .responseError(response, error)
            } else {
                return .responseError(response, nil)
            }
        } else {
            return nil
        }
    }

    /// Decodes raw data into a specified Decodable type asynchronously.
    ///
    /// The `decodeValue` function attempts to decode the provided data into a specific
    /// Decodable type. It handles special cases where the expected type is `Data` or `String`.
    /// If the expected type is any other Decodable, it uses a detached task to perform the
    /// decoding asynchronously.
    ///
    /// - Parameters:
    ///   - data: The raw data to decode.
    ///   - decoder: The `JSONDecoder` instance used to decode the data.
    /// - Returns: The decoded value of type `T`.
    /// - Throws:
    ///   - `APIError.networkError`: If the data cannot be converted to a string when the expected type is `String`.
    ///   - `APIError.decoderError`: If an error occurs during decoding.
    func decodeValue<T: Decodable & Sendable>(from data: Data, decoder: JSONDecoder) async throws(APIClientError) -> T {
        let value: T

        if data.isEmpty, T.self is OptionalDecoding.Type {
            value = Optional<Decodable>.none as! T
        } else if T.self == Data.self {
            value = data as! T
        } else if T.self == String.self {
            guard let string = String(data: data, encoding: .utf8) else {
                throw APIClientError.networkError(URLError(.badServerResponse))
            }
            value = string as! T
        } else {
            // Check special case when backend returns empty json "{}"
            if #available(iOS 16.0, *) {
                if T.self is OptionalDecoding.Type,
                    data.count == 2, data.contains([0x7b, 0x7d]) {
                    return Optional<Decodable>.none as! T
                }
            } else {
                if T.self is OptionalDecoding.Type,
                    data.count == 2, data[0] == 0x7b, data[1] == 0x7d {
                    return Optional<Decodable>.none as! T
                }
            }

            do {
                value = try await Task.detached {
                    return try decoder.decode(T.self, from: data)
                }.value
            } catch {
                throw APIClientError.decoderError(error)
            }
        }

        return value
    }
}

/// A structure representing the configuration for an API client.
///
/// The `Configuration` struct stores encoding/decoding strategies,
/// creating fresh encoder/decoder instances each time for thread safety.
public struct Configuration: Sendable {

    /// The date decoding strategy for JSON responses.
    public let dateDecodingStrategy: JSONDecoder.DateDecodingStrategy

    /// The date encoding strategy for JSON requests.
    public let dateEncodingStrategy: JSONEncoder.DateEncodingStrategy

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

    /// Initializes a new instance of `Configuration` with default strategies.
    ///
    /// Default strategies use seconds since 1970 for date encoding/decoding.
    public init() {
        self.dateDecodingStrategy = .secondsSince1970
        self.dateEncodingStrategy = .secondsSince1970
    }

    /// Initializes a new instance of `Configuration` with custom strategies.
    ///
    /// - Parameters:
    ///   - dateDecodingStrategy: The strategy for decoding dates.
    ///   - dateEncodingStrategy: The strategy for encoding dates.
    public init(
        dateDecodingStrategy: JSONDecoder.DateDecodingStrategy,
        dateEncodingStrategy: JSONEncoder.DateEncodingStrategy
    ) {
        self.dateDecodingStrategy = dateDecodingStrategy
        self.dateEncodingStrategy = dateEncodingStrategy
    }
}

public protocol OptionalDecoding { }
extension Optional: OptionalDecoding {}

public extension APIClient {
    enum Constants {
        public static let notFoundErrorCode = 404
    }
}
