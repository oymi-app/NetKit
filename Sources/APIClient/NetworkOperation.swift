import Foundation

public typealias BaseUrlProvider = () -> URL?

/// A class for managing network operations with retries and middleware.
///
/// The `NetworkOperation` class represents a network operation that communicates
/// with an endpoint, using an authentication mechanism, a transport layer, and a retry
/// strategy.
class NetworkOperation: @unchecked Sendable {

    public typealias Middleware = (@Sendable (inout URLRequest, Endpoint) async throws(APIClientError) -> Void)

    /// The endpoint associated with the network operation.
    private let endpoint: Endpoint

    /// Middleware to be applied to requests before they are sent.
    private let requestMiddleware: Middleware

    /// The transport layer for sending HTTP requests.
    internal let transport: HTTPTransport

    /// The strategy for retrying network operations.
    private let retryStrategy: RetryStrategy

    /// An iterator to determine the delay between retries.
    private let retryDelayIterator: AnyIterator<TimeInterval>

    /// The current retry count for the operation.
    private var retryCount: Int = 0

    /// Initializes a new instance of `NetworkOperation`.
    ///
    /// - Parameters:
    ///   - baseURL: The base URL for the network operation.
    ///   - requestMiddleware: The `Middleware` instance for request middleware..
    ///   - transport: The `HTTPTransport` instance for sending requests.
    ///   - endpoint: The `Endpoint` representing the endpoint to interact with.
    ///   - retryStrategy: The `RetryStrategy` for managing retries.
    init(
        requestMiddleware: @escaping Middleware,
        transport: HTTPTransport,
        endpoint: Endpoint,
        retryStrategy: RetryStrategy
    ) {
        self.requestMiddleware = requestMiddleware
        self.transport = transport
        self.endpoint = endpoint
        self.retryStrategy = retryStrategy
        self.retryDelayIterator = retryStrategy.makeDelayIterator()
    }

    /// Starts the network request, handling authorization and retries.
    ///
    /// - Throws: An error if the request fails, if there's a network error, or if
    ///           the task is cancelled.
    /// - Returns: A `Response<Data>` representing the HTTP response.
    func startRequest() async throws(APIClientError) -> Response<Data> {
        // Generate a unique id
        let requestId = UUID().uuidString

        do {
            // Form request
            var request = try RequestBuilder()
                .build(using: endpoint)
            try await makeUpWithMiddleware(request: &request, endpoint: endpoint)

            // Log request
            log(message: "⬆️ [\(requestId)] \(request.curlString)")

            // Get data
            let response = try await proceedWithRequest(request)

            // Log the data and return
            let data = response.data
            let responseBody = String(bytes: data, encoding: .utf8)
            log(message: "⬇️ [\(requestId)] \(responseBody ?? "Empty response")")

            return response
        } catch {
            log(message: "❌ [\(requestId)] Error: \(error.localizedDescription).")
            throw error
        }
    }

    private func makeUpWithMiddleware(request: inout URLRequest, endpoint: Endpoint) async throws(APIClientError) {
        try await requestMiddleware(&request, endpoint)
    }

    internal func proceedWithRequest(_ urlRequest: URLRequest) async throws(APIClientError) -> Response<Data> {
        do {
            return try await requestData(urlRequest)
        } catch {
            let apiError: APIClientError

            if let error = error as? APIClientError {
                apiError = error
            } else {
                apiError = (error as? URLError).map { .networkError($0) } ?? .transport(error)
            }

            if case .networkError(URLError.cancelled) = apiError {
                throw apiError
            } else {
                return try await retryRequest(with: apiError)
            }
        }
    }

    internal func requestData(_ urlRequest: URLRequest) async throws -> Response<Data> {
        let (data, response) = try await transport.send(request: urlRequest)

        if Task.isCancelled {
            throw APIClientError.networkError(URLError(.cancelled))
        }

        return Response(value: data, data: data, response: response)
    }

    private func retryRequest(with error: APIClientError) async throws(APIClientError) -> Response<Data> {
        guard retryCount < retryStrategy.maxRetryCount else {
            throw error
        }

        retryCount += 1

        guard retryStrategy.retryInterval != .never else {
            return try await startRequest()
        }

        guard let delay = retryDelayIterator.next() else {
            throw error
        }

        do {
            if #available(iOS 16.0, *) {
                try await Task.sleep(for: .seconds(delay))
            } else {
                try await Task.sleep(nanoseconds: UInt64(delay) * NSEC_PER_SEC)
            }
        } catch {
            throw APIClientError.aborted(error)
        }

        return try await startRequest()
    }
}

/// Represents a network operation specialized for uploading data asynchronously.
final class UploadNetworkOperation: NetworkOperation, @unchecked Sendable {

    private let progressHandler: ((Double) -> Void)

    /// Initializes an upload network operation with necessary parameters.
    ///
    /// - Parameters:
    ///   - baseURL: The base URL for the API endpoint.
    ///   - requestMiddleware: Middlewares for modifying outgoing requests.
    ///   - transport: The HTTP transport responsible for sending requests.
    ///   - endpoint: The endpoint to which the data will be uploaded.
    ///   - retryStrategy: The strategy for retrying failed network requests.
    ///   - progressHandler: Closure to handle and report upload progress updates.
    init(
        requestMiddleware: @escaping Middleware,
        transport: HTTPTransport,
        endpoint: Endpoint,
        retryStrategy: RetryStrategy,
        progressHandler: @escaping (Double) -> Void
    ) {
        self.progressHandler = progressHandler

        super.init(requestMiddleware: requestMiddleware,
                   transport: transport,
                   endpoint: endpoint,
                   retryStrategy: retryStrategy)
    }

    override internal func requestData(_ urlRequest: URLRequest) async throws -> Response<Data> {
        let (bytes, response) = try await transport.bytes(request: urlRequest)

        if Task.isCancelled {
            throw APIClientError.networkError(URLError(.cancelled))
        }

        let length = Int(response.expectedContentLength)
        var data = Data(capacity: length)

        var progress: Double = 0
        for try await byte in bytes {
            data.append(byte)

            let currentProgress = Double(data.count) / Double(length)

            // Skip minor changes (less than 1%)
            if Int(progress * 100) != Int(currentProgress * 100) {
                await MainActor.run {
                    progressHandler(currentProgress)
                }

                progress = currentProgress
            }
        }

        return Response(value: data, data: data, response: response)
    }
}
