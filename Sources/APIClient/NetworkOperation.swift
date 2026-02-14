import Foundation
import Synchronization

/// A class for managing network operations with retries and middleware.
///
/// The `NetworkOperation` class represents a network operation that communicates
/// with an endpoint, using a transport layer and a retry strategy.
class NetworkOperation: @unchecked Sendable {

    public typealias Middleware = (@Sendable (inout URLRequest, any Endpoint) async throws(APIClientError) -> Void)

    /// The configuration for building requests.
    let configuration: Configuration

    /// The endpoint associated with the network operation.
    private let endpoint: any Endpoint

    /// Middleware to be applied to requests before they are sent.
    private let requestMiddleware: Middleware

    /// The transport layer for sending HTTP requests.
    internal let transport: HTTPTransport

    /// The strategy for retrying network operations.
    private let retryStrategy: RetryStrategy

    /// Mutable state protected by a Mutex for thread safety.
    private let mutableState: Mutex<(retryCount: Int, delayIterator: AnyIterator<TimeInterval>)>

    /// Initializes a new instance of `NetworkOperation`.
    ///
    /// - Parameters:
    ///   - configuration: The client configuration for building requests.
    ///   - requestMiddleware: The middleware closure for request modification.
    ///   - transport: The `HTTPTransport` instance for sending requests.
    ///   - endpoint: The `Endpoint` representing the endpoint to interact with.
    ///   - retryStrategy: The `RetryStrategy` for managing retries.
    init(
        configuration: Configuration,
        requestMiddleware: @escaping Middleware,
        transport: HTTPTransport,
        endpoint: any Endpoint,
        retryStrategy: RetryStrategy
    ) {
        self.configuration = configuration
        self.requestMiddleware = requestMiddleware
        self.transport = transport
        self.endpoint = endpoint
        self.retryStrategy = retryStrategy
        self.mutableState = Mutex((retryCount: 0, delayIterator: retryStrategy.makeDelayIterator()))
    }

    /// Starts the network request, handling retries.
    ///
    /// - Throws: An `APIClientError` if the request fails after all retries.
    /// - Returns: A `Response<Data>` representing the HTTP response.
    func startRequest() async throws(APIClientError) -> Response<Data> {
        do {
            var request = try RequestBuilder(configuration: configuration)
                .build(for: endpoint)
            try await requestMiddleware(&request, endpoint)

            let response = try await proceedWithRequest(request)
            return response
        } catch {
            throw error
        }
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

            guard case .networkError(URLError.cancelled) = apiError else {
                return try await retryRequest(with: apiError)
            }
            throw apiError
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
        let retryInfo: (shouldRetry: Bool, delay: TimeInterval?) = mutableState.withLock { state in
            guard state.retryCount < retryStrategy.maxRetryCount else {
                return (false, nil)
            }
            state.retryCount += 1

            guard retryStrategy.retryInterval != .never else {
                return (true, nil)
            }

            return (true, state.delayIterator.next())
        }

        guard retryInfo.shouldRetry else {
            throw error
        }

        if let delay = retryInfo.delay {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                throw APIClientError.aborted(error)
            }
        }

        return try await startRequest()
    }
}

/// Represents a network operation specialized for downloading data with progress tracking.
final class UploadNetworkOperation: NetworkOperation, @unchecked Sendable {

    private let progressHandler: @Sendable (Double) -> Void

    /// Initializes a progress-tracking network operation.
    ///
    /// - Parameters:
    ///   - configuration: The client configuration.
    ///   - requestMiddleware: Middlewares for modifying outgoing requests.
    ///   - transport: The HTTP transport responsible for sending requests.
    ///   - endpoint: The endpoint for the request.
    ///   - retryStrategy: The strategy for retrying failed network requests.
    ///   - progressHandler: Closure to handle and report download progress updates.
    init(
        configuration: Configuration,
        requestMiddleware: @escaping Middleware,
        transport: HTTPTransport,
        endpoint: any Endpoint,
        retryStrategy: RetryStrategy,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) {
        self.progressHandler = progressHandler

        super.init(
            configuration: configuration,
            requestMiddleware: requestMiddleware,
            transport: transport,
            endpoint: endpoint,
            retryStrategy: retryStrategy
        )
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
