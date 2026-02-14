import Foundation

/// Enum representing errors that can occur when interacting with an API.
public enum APIClientError: Swift.Error, Sendable {

    /// An error occurred while creating or sending an HTTP request.
    case requestError(Swift.Error)

    /// An error related to network issues.
    case networkError(URLError)  // Swift.Error

    /// An error related to an invalid or unexpected HTTP response.
    case responseError(HTTPURLResponse, ErrorResponse?)

    /// An error related to decoding or parsing the response data.
    case decoderError(Swift.Error?)

    /// An error related to encoding data.
    case encoderError(Swift.Error?)

    /// A general transport-related error.
    case transport(Swift.Error)

    case aborted(Swift.Error)
}

extension APIClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .requestError:
            return "Can't create URL request."
        case .networkError:
            return "Network error."
        case let .responseError(res, _):
            return "Can't handle response: HTTP/\(res.statusCode)."
        case .decoderError:
            return "Failure to decode response."
        case .transport:
            return "Transport error."
        case .encoderError(let error):
            return error?.localizedDescription ?? "Unknown error"
        case .aborted(let error):
            return "Aborted due to error: \(error.localizedDescription)."
        }
    }

    /// A computed property to determine if an error is a cancellation error.
    ///
    /// The `isCancellationError` property checks whether the `Error` instance
    /// represents a network error caused by a cancellation event.
    public var isCancellationError: Bool {
        if case .networkError(let urlError) = self {
            return urlError.code == .cancelled
        }

        return false
    }

    /// A computed property to determine if an error is a not found error.
    public var isNotFoundError: Bool {
        if case .responseError(let res, _) = self {
            return res.statusCode == 404
        }

        return false
    }

    var isUnauthorizedError: Bool {
        if case .responseError(let res, _) = self {
            return res.statusCode == 401
        }

        return false
    }

    public var isHTTP5xxError: Bool {
        switch self {
        case .responseError(let res, _):
            return res.isHTTP5xxError
        default:
            return false
        }
    }
}

/// Represents an error response from an API.
///
/// The `ErrorResponse` struct encapsulates information about an error returned
/// by an API, typically including error details and additional context.
public struct ErrorResponse: Codable, Sendable {

    public let code: Int
    public let message: String?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decode(Int.self, forKey: .code)
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
    }

    enum CodingKeys: String, CodingKey {
        case code
        case message
    }
}

/// Enum representing errors related to internal request processing.
///
/// The `InternalRequestError` enum contains errors specific to request-related
/// issues, such as invalid URL components.
public enum InternalRequestError: LocalizedError, Equatable, Sendable {

    /// Indicates that URL components are invalid.
    case urlComponentsAreInvalid

    public var errorDescription: String? {
        switch self {
        case .urlComponentsAreInvalid:
            return "Invalid components"
        }
    }
}

/// Enum representing errors related to internal transport issues.
///
/// The `InternalTransportError` enum contains errors that occur during
/// HTTP transport, such as invalid or unexpected responses.
public enum InternalTransportError: LocalizedError, Sendable {

    /// Indicates that an HTTP response is invalid.
    ///
    /// This could be due to an unexpected type of response or missing expected data.
    case invalidResponse(URLResponse?)

    public var errorDescription: String? {
        switch self {
        case let .invalidResponse(response):
            return "Invalid response. Expected HTTPURLResponse, got \(response.map { "\($0.self)" } ?? "(nil)")."
        }
    }
}
