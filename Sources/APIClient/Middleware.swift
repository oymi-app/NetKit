import Foundation

/// A protocol that defines middleware behavior for modifying URLRequest  for auth purpose
public protocol AuthMiddleware: AnyObject, Sendable {

    /// Modifies the provided URLRequest for a specific endpoint asynchronously.
    ///
    /// - Parameters:
    ///   - request: The inout URLRequest to be modified.
    ///   - endpoint: The specific endpoint for which the request is being made.
    ///
    /// - Throws: An error if there's an issue during the request modification process.
    func auth(request: inout URLRequest, for endpoint: Endpoint, force: Bool) async throws
    
    /// Handles errors that occur during the response handling process.
    ///
    /// - Parameter error: The error that occurred.
    func handle(error: any Error) async throws
}

/// A protocol that defines middleware behavior for modifying URLRequest objects
/// before they are sent.
public protocol RequestMiddleware: AnyObject, Sendable {
    
    /// Modifies the provided URLRequest for a specific endpoint asynchronously.
    ///
    /// - Parameters:
    ///   - request: The inout URLRequest to be modified.
    ///   - endpoint: The specific endpoint for which the request is being made.
    ///
    /// - Throws: An error if there's an issue during the request modification process.
    func makeUp(request: inout URLRequest, for endpoint: Endpoint) async throws
}

/// A protocol that defines middleware behavior for handling responses and errors
/// after they are received.
public protocol ResponseMiddleware: AnyObject, Sendable {
    /// Handles a response with a generic value.
    ///
    /// - Parameter response: The response object containing the value.
    func handle<T: Sendable>(response: Response<T>)
    
    /// Handles a response with no associated value (Void).
    ///
    /// - Parameter response: The response object without a value.
    func handle(response: Response<Void>)
    
    /// Handles errors that occur during the response handling process.
    ///
    /// - Parameter error: The error that occurred.
    func handle(error: APIClientError, response: HTTPURLResponse)

    /// Handles all errors that occur during the request flow.
    ///
    /// - Parameter error: The error that occurred.
    func handle(error: APIClientError)
}

public extension ResponseMiddleware {
    func handle<T: Sendable>(response: Response<T>) {
        // NOP
    }
    
    func handle(response: Response<Void>) {
        // NOP
    }
    
    func handle(error: APIClientError, response: HTTPURLResponse) {
        // NOP
    }

    func handle(error: APIClientError) {
        
    }
}
