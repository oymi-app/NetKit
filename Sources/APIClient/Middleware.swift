import Foundation

/// A protocol that defines middleware behavior for modifying URLRequest objects
/// before they are sent.
public protocol RequestMiddleware: Sendable {

    /// Modifies the provided URLRequest for a specific endpoint asynchronously.
    ///
    /// - Parameters:
    ///   - request: The inout URLRequest to be modified.
    ///   - endpoint: The specific endpoint for which the request is being made.
    ///
    /// - Throws: An error if there's an issue during the request modification process.
    func makeUp(request: inout URLRequest, for endpoint: any Endpoint) async throws
}

/// A protocol that defines middleware behavior for processing responses
/// before they are decoded.
///
/// Response middlewares form a chain that can inspect, transform, or reject
/// raw responses before decoding occurs.
public protocol ResponseMiddleware: Sendable {

    /// Processes a raw response, optionally transforming it.
    ///
    /// - Parameters:
    ///   - response: The raw response containing data and HTTP response.
    ///   - endpoint: The endpoint that produced this response.
    /// - Returns: The (possibly transformed) response to pass to the next middleware or decoder.
    /// - Throws: An `APIClientError` to reject the response.
    func modify(response: Response<Data>, for endpoint: any Endpoint) async throws(APIClientError) -> Response<Data>
}
