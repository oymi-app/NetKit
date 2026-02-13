import Foundation

/// Protocol representing an API endpoint.
public protocol Endpoint: Sendable {

    /// The base URL to be used for constructing requests.
    var baseURL: URL { get }

    /// The path for the HTTP endpoint.
    var path: String { get }

    /// The HTTP method used for the endpoint.
    var method: HTTPMethod { get }

    /// Indicates whether authorization is needed for the endpoint.
    var isAuthorizationNeeded: Bool { get }

    /// The data to be sent with the HTTP request.
    var httpData: HTTPData { get }

    /// Optional HTTP header fields for the request.
    var httpHeaderFields: [String: String]? { get }

    /// The retry strategy for the HTTP request.
    var retryStrategy: RetryStrategy { get }
}

public extension Endpoint {
    var httpHeaderFields: [String: String]? {
        return nil
    }

    var retryStrategy: RetryStrategy {
        .default
    }
}

/// A type that represents an HTTP endpoint with a predefined base URL.
///
/// `URLEndpoint` is designed for use cases where the full URL is known in advance,
/// such as accessing static files, resources hosted on a CDN, or third-party APIs with fixed URLs.
/// By encapsulating the complete `URL`, this type simplifies endpoint configuration and usage.
///
/// `URLEndpoint` conforms to the `Endpoint` protocol, ensuring compatibility with
/// existing systems or frameworks designed to work with `Endpoint` instances.
public struct URLEndpoint: Endpoint {
    public let baseURL: URL
    public let path: String
    public let method: HTTPMethod
    public let isAuthorizationNeeded: Bool
    public let httpData: HTTPData
    public let httpHeaderFields: [String: String]?
    public let retryStrategy: RetryStrategy

    public let url: URL

    public init(url: URL,
                method: HTTPMethod = .GET,
                isAuthorizationNeeded: Bool = true,
                httpData: HTTPData = .plain,
                httpHeaderFields: [String : String]? = nil,
                retryStrategy: RetryStrategy = .default) throws {
        self.url = url
        self.baseURL = try url.hostUrl
        self.path = url.curPath
        self.method = method
        self.isAuthorizationNeeded = isAuthorizationNeeded
        self.httpData = httpData
        self.httpHeaderFields = httpHeaderFields
        self.retryStrategy = retryStrategy
    }
}

/// Represents an HTTP data.
@frozen
public enum HTTPData: @unchecked Sendable {

    /// No data.
    case plain

    /// Raw data.
    case data(Data)

    /// JSON-encodable data.
    case JSONEncodable(Encodable)

    /// Parameters with a specified encoding.
    case parameters(parameters: [String: Any], encoding: ParameterEncoding)

    // Multipart form data
    case multipartData(MultipartForm)
}

extension HTTPData {
    public struct MultipartForm: @unchecked Sendable {
        public struct Data {
            let data: Foundation.Data
            let name: String
            let fileName: String
            let mimeType: String

            public init(data: Foundation.Data, name: String, fileName: String, mimeType: String) {
                self.data = data
                self.name = name
                self.fileName = fileName
                self.mimeType = mimeType
            }
        }

        let parameters: [String: Any]
        let data: [Data]
        let boundary: UUID

        public init(
            data: Foundation.Data,
            parameters: [String: Any] = [:],
            name: String,
            fileName: String,
            mimeType: String,
            boundary: UUID = UUID()
        ) {
            self.parameters = parameters
            self.data = [Data(data: data, name: name, fileName: fileName, mimeType: mimeType)]
            self.boundary = boundary
        }

        public init (parameters: [String: Any], data: [Data], boundary: UUID = UUID()) {
            self.parameters = parameters
            self.data = data
            self.boundary = boundary
        }
    }
}

extension HTTPData {
    func encode(_ urlRequest: URLRequest) throws -> URLRequest {
        var urlRequest = urlRequest

        switch self {
        case .plain:
            break
        case .data(let data):
            urlRequest.httpBody = data
        case .JSONEncodable(let encodable):
            if urlRequest.allHTTPHeaderFields?["Content-Type"] == nil {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = .sortedKeys

            urlRequest.httpBody = try encoder.encode(encodable)
        case .parameters(let parameters, let encoding):
            return try encoding.encode(urlRequest, with: parameters)

        case .multipartData(let multipartFormData):
            let boundary = multipartFormData.boundary.uuidString

            var httpBody = Data()

            let parameters = multipartFormData.parameters
            for parameter in parameters {
                httpBody.append(Data("--\(boundary)\r\n".utf8))
                httpBody.append(Data("Content-Disposition: form-data; name=\"\(parameter.key)\"\r\n\r\n".utf8))
                httpBody.append(Data("\(parameter.value)\r\n".utf8))
            }

            for item in multipartFormData.data {
                httpBody.append(Data("--\(boundary)\r\n".utf8))
                httpBody.append(Data("Content-Disposition: form-data; name=\"\(item.name)\"; filename=\"\(item.fileName)\"\r\n".utf8))
                httpBody.append(Data("Content-Type: \(item.mimeType)\r\n\r\n".utf8))
                httpBody.append(item.data)
                httpBody.append(Data("\r\n".utf8))
            }

            httpBody.append(Data("--\(boundary)--\r\n".utf8))

            urlRequest.httpBody = httpBody
            urlRequest.setValue(
                "multipart/form-data; boundary=\(boundary)",
                forHTTPHeaderField: "Content-Type"
            )
            urlRequest.setValue("\(httpBody.count)", forHTTPHeaderField: "Content-Length")
        }

        return urlRequest
    }
}

/// A type alias representing parameters to be encoded in a URL request.
public typealias Parameters = [String: Any]

/// A protocol defining a method for encoding parameters in a URL request.
public protocol ParameterEncoding: Sendable {

    /// Encodes the given parameters into the provided URL request.
    ///
    /// - Parameters:
    ///   - urlRequest: The `URLRequest` object to be encoded with parameters.
    ///   - parameters: The parameters to be encoded into the URL request.
    /// - Returns: The encoded `URLRequest` with the parameters included.
    /// - Throws: An error if encoding fails.
    func encode(_ urlRequest: URLRequest, with parameters: Parameters?) throws -> URLRequest
}

public struct URLEncoding: ParameterEncoding, Sendable {
    public static var `default`: URLEncoding { URLEncoding() }

    public func encode(_ urlRequest: URLRequest, with parameters: Parameters?) throws -> URLRequest {
        var urlRequest = urlRequest

        guard let parameters else { return urlRequest }

        if urlRequest.method != nil {
            guard let url = urlRequest.url else {
                let error = URLError.init(URLError.badURL)
                throw APIClientError.networkError(error)
            }

            if var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false), !parameters.isEmpty {
                let percentEncodedQuery = (urlComponents.percentEncodedQuery.map { $0 + "&" } ?? "") + query(parameters)
                urlComponents.percentEncodedQuery = percentEncodedQuery
                urlRequest.url = urlComponents.url
            }
        }

        return urlRequest
    }

    public func queryComponents(fromKey key: String, value: Any) -> [(String, String)] {
        var components: [(String, String)] = []
        switch value {
        case let dictionary as [String: Any]:
            for (nestedKey, value) in dictionary {
                components += queryComponents(fromKey: "\(key)[\(nestedKey)]", value: value)
            }
        case let array as [String]:
            components += queryComponents(fromKey: "\(key)", value: array.joined(separator: ","))
        case let array as [Any]:
            for item in array {
                components += queryComponents(fromKey: "\(key)[]", value: item)
            }
        case let bool as Bool:
            components.append((escape(key), bool ? "true" : "false"))
        default:
            components.append((escape(key), escape("\(value)")))
        }
        return components
    }

    public func escape(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .queryAllowed) ?? string
    }

    private func query(_ parameters: [String: Any]) -> String {
        var components: [(String, String)] = []

        for key in parameters.keys.sorted(by: <) {
            let value = parameters[key]!
            components += queryComponents(fromKey: key, value: value)
        }
        return components.map { "\($0)=\($1)" }.joined(separator: "&")
    }
}

public struct JSONEncoding: ParameterEncoding, Sendable {
    public enum Error: Swift.Error {
        case invalidJSON

        public var localizedDescription: String {
            "JSON is invalid"
        }
    }

    public static var `default`: JSONEncoding { JSONEncoding() }

    public func encode(_ urlRequest: URLRequest, with parameters: Parameters?) throws -> URLRequest {
        return try encode(urlRequest, withJSONObject: parameters)
    }

    public func encode(_ urlRequest: URLRequest, withJSONObject jsonObject: Any? = nil) throws -> URLRequest {
        var urlRequest = urlRequest

        guard let jsonObject else { return urlRequest }

        guard JSONSerialization.isValidJSONObject(jsonObject) else {
            throw APIClientError.encoderError(Error.invalidJSON)
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: jsonObject)

            if urlRequest.allHTTPHeaderFields?["Content-Type"] == nil {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            urlRequest.httpBody = data
        } catch {
            throw APIClientError.encoderError(error)
        }

        return urlRequest
    }
}

extension CharacterSet {
    public static let queryAllowed: CharacterSet = {
        let generalDelimitersToEncode = ":#[]@"
        let subDelimitersToEncode = "!$&'()*+,;="
        let encodableDelimiters = CharacterSet(charactersIn: "\(generalDelimitersToEncode)\(subDelimitersToEncode)")

        return CharacterSet.urlQueryAllowed.subtracting(encodableDelimiters)
    }()
}

fileprivate extension URL {
    var curPath: String {
        get {
            if #available(iOS 16.0, *) {
                return path(percentEncoded: false)
            } else {
                return path
            }
        }
    }

    var hostUrl: URL {
        get throws {
            let baseUrl: URL? = {
                if #available(iOS 16.0, *) {
                    if let host = host(percentEncoded: false) {
                        return URL(string: host)
                    }
                } else {
                    if let host {
                        return URL(string: host)
                    }
                }

                return nil
            }()

            if let baseUrl {
                return baseUrl
            } else {
                throw APIClientError.requestError(InternalRequestError.urlComponentsAreInvalid)
            }
        }
    }
}
