import Foundation

/// An enumeration containing common HTTP header keys.
public enum HTTPHeader: Sendable {

    /// Authorization header key
    public static let authorization = "Authorization"

    /// User agent header key
    public static let userAgent = "User-Agent"
}

/// An enumeration defining URL schemes.
private enum Scheme: Sendable {
    /// Default scheme is HTTPS
    static let https: String = "https"
}

/// A class for building `URLRequest` objects with various configuration options.
///
/// `RequestBuilder` is used to construct HTTP requests for a given base URL and endpoint.
/// It supports adding custom user agent and authorization token,
class RequestBuilder: @unchecked Sendable {
    private var userAgent: String?
    private var authToken: String?

    /// Builds a `URLRequest` using the specified endpoint.
    /// - Parameter endpoint: The endpoint defining the request path, method, query parameters, body, and headers.
    /// - Returns: A configured `URLRequest` based on the endpoint's settings.
    /// - Throws: An error if any value throws an error during building.
    func build(using endpoint: Endpoint) throws(APIClientError) -> URLRequest {
        return try build(using: endpoint.baseURL, endpoint: endpoint)
    }
    
    func build(using baseURL: URL, endpoint: Endpoint) throws(APIClientError) -> URLRequest {
        let urlComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)

        guard var components = urlComponents else {
            throw APIClientError.requestError(InternalRequestError.urlComponentsAreInvalid)
        }

        components.scheme = Scheme.https

        guard var url = components.url else {
            throw APIClientError.requestError(InternalRequestError.urlComponentsAreInvalid)
        }

        if #available(iOS 16.0, *) {
            url.append(path: endpoint.path, directoryHint: .notDirectory)
        } else {
            url.appendPathComponent(endpoint.path, isDirectory: false)
        }
        
        return try build(with: url, for: endpoint)
    }
    
    func build(with url: URL, for endpoint: Endpoint) throws(APIClientError) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue

        do {
            request = try endpoint.httpData.encode(request)

            if let userAgent {
                request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
            }

            if let authToken {
                request.addValue(authToken, forHTTPHeaderField: "Authorization")
            }

            if let httpHeaderFields = endpoint.httpHeaderFields {
                for (key, value) in httpHeaderFields {
                    request.addValue(value, forHTTPHeaderField: key)
                }
            }

            return request
        } catch {
            throw APIClientError.encoderError(error)
        }
    }
}

extension RequestBuilder {

    /// Adds a user agent to the request.
    /// - Parameter userAgent: The user agent to add.
    /// - Returns: The current `RequestBuilder` instance for chaining.
    func addUserAgent(_ userAgent: String?) -> RequestBuilder {
        self.userAgent = userAgent

        return self
    }

    /// Adds an authorization token to the request.
    /// - Parameter authToken: The authorization token to add.
    /// - Returns: The current `RequestBuilder` instance for chaining.
    func addAuthToken(_ authToken: String?) -> RequestBuilder {
        self.authToken = authToken

        return self
    }
}
