import Foundation

/// Enum representing HTTP methods.
public enum HTTPMethod: String, Sendable {
    /// Represents an HTTP GET request.
    case GET

    /// Represents an HTTP POST request.
    case POST

    /// Represents an HTTP PUT request.
    case PUT

    /// Represents an HTTP PATCH request.
    case PATCH

    /// Represents an HTTP DELETE request.
    case DELETE

    public init?(rawValue: String?) {
        switch rawValue {
        case "get", "GET":
            self = .GET
        case "post", "POST":
            self = .POST
        case "put", "PUT":
            self = .PUT
        case "patch", "PATCH":
            self = .PATCH
        case "delete", "DELETE":
            self = .DELETE
        default:
            return nil
        }
    }
}
