import Foundation

/// Protocol for HTTP transport services.
///
/// The `HTTPTransport` protocol defines a method for sending HTTP requests
/// and receiving responses. 
public protocol HTTPTransport: AnyObject, Sendable {

    /// Sends an HTTP request and returns the response data and HTTP response.
    ///
    /// - Parameter request: A `URLRequest` object representing the HTTP request to be sent.
    /// - Returns: A tuple containing the response `Data` and the `HTTPURLResponse`.
    /// - Throws: An error if the HTTP request fails, if there's a network error, or if the response is invalid.
    func send(request: URLRequest) async throws -> (Data, HTTPURLResponse)
    
    /// Sends an HTTP request and returns the response bytes and HTTP response.
    ///
    /// - Parameter request: A `URLRequest` object representing the HTTP request to be sent.
    /// - Returns: A tuple containing the response `URLSession.AsyncBytes` and the `HTTPURLResponse`.
    /// - Throws: An error if the HTTP request fails, if there's a network error, or if the response is invalid.
    func bytes(request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse)
}
