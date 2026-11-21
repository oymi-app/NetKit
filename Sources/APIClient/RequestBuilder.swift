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

/// A structure for building `URLRequest` objects from a configuration and endpoint.
///
/// `RequestBuilder` constructs HTTP requests using the client's `Configuration`
/// (base URL, encoder, timeout, headers, cache policy) and endpoint properties.
struct RequestBuilder: Sendable {

    private let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Builds a `URLRequest` for the given endpoint using the client's configuration.
    ///
    /// - Parameter endpoint: The endpoint defining the request path, method, body, and headers.
    /// - Returns: A configured `URLRequest`.
    /// - Throws: An `APIClientError` if URL construction or encoding fails.
    func build(for endpoint: any Endpoint) throws(APIClientError) -> URLRequest {
        let urlComponents = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)

        guard var components = urlComponents else {
            throw APIClientError.requestError(InternalRequestError.urlComponentsAreInvalid)
        }

        if components.scheme?.isEmpty ?? true {
            components.scheme = Scheme.https
        }

        guard var url = components.url else {
            throw APIClientError.requestError(InternalRequestError.urlComponentsAreInvalid)
        }

        url.append(path: endpoint.path, directoryHint: .notDirectory)

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.timeoutInterval = configuration.timeoutInterval
        request.cachePolicy = configuration.cachePolicy

        do {
            request = try endpoint.httpData.encode(request, using: configuration.makeEncoder())

            // Apply default headers from configuration
            for (key, value) in configuration.defaultHeaders {
                request.addValue(value, forHTTPHeaderField: key)
            }

            // Apply endpoint-specific headers (can override defaults)
            if let httpHeaderFields = endpoint.httpHeaderFields {
                for (key, value) in httpHeaderFields {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }

            return request
        } catch {
            throw APIClientError.encoderError(error)
        }
    }
}
