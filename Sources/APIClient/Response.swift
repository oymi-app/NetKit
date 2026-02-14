import Foundation

/// A structure representing an HTTP response with a generic value.
public struct Response<T: Sendable>: Sendable {

    /// The main value of the response, of generic type `T`.
    public let value: T

    /// The `HTTPURLResponse` associated with this response, containing HTTP status and headers.
    public let response: HTTPURLResponse

    /// The raw data received from the network request.
    public let data: Data

    /// Initializes a `Response` with a given value, data, and HTTP response.
    /// - Parameters:
    ///   - `value`: The primary response value.
    ///   - `data`: The raw data of the response.
    ///   - `response`: The associated `HTTPURLResponse`.
    public init(value: T, data: Data, response: HTTPURLResponse) {
        self.value = value
        self.data = data
        self.response = response
    }
}

extension Response {
    /// The HTTP status code of the response.
    public var statusCode: Int? { response.statusCode }

    /// Transforms the response's value using a closure, creating a new `Response` with the transformed value.
    /// - Parameter closure: A closure that takes the current value and returns a transformed value.
    /// - Returns: A new `Response` with the transformed value, same raw data, and HTTP response.
    /// - Throws: If the closure throws an error during transformation, this method will rethrow it.
    public func map<U>(_ closure: (T) throws -> U) rethrows -> Response<U> {
        Response<U>(value: try closure(value), data: data, response: response)
    }
}

public protocol PageElement {
    static var responseName: String { get }
}

/// A structure that represents the result of a paginated query.
public struct PaginationPayload<Element: Decodable & Sendable & PageElement>: Decodable, Sendable {

    struct Pagination: Decodable {
        let nextCursor: String?
        let hasMore: Bool
        let count: Int

        enum CodingKeys: String, CodingKey {
            case nextCursor = "next_cursor"
            case hasMore = "has_more"
            case count
        }
    }

    /// The array of elements representing the items in the current page.
    public var data: [Element]

    private let pagination: Pagination

    /// The total number of items across all pages.
    public var total: Int { return pagination.count }

    /// A Boolean value indicating whether there are more pages to retrieve.
    ///
    /// This is determined by comparing the `limit` with the `total`. If `limit` is less than `total`,
    /// it indicates that there are more pages available to retrieve.
    ///
    /// - Returns: `true` if there are more pages available, otherwise `false`.
    public var hasNextPage: Bool {
        pagination.hasMore
    }

}
