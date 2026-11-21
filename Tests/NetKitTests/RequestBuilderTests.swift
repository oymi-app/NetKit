import Foundation
import Testing
@testable import NetKit

@Suite("RequestBuilder")
struct RequestBuilderTests {
    private struct TestEndpoint: Endpoint {
        var path = "/auth/token"
        var method = HTTPMethod.POST
        var httpData = HTTPData.plain
    }

    private func url(baseURL: String) throws -> String? {
        let builder = RequestBuilder(configuration: Configuration(baseURL: URL(string: baseURL)!))
        return try builder.build(for: TestEndpoint()).url?.absoluteString
    }

    @Test("Keeps an http base URL, including its port")
    func keepsHTTP() throws {
        #expect(try url(baseURL: "http://localhost:8080") == "http://localhost:8080/auth/token")
    }

    @Test("Keeps an https base URL")
    func keepsHTTPS() throws {
        #expect(try url(baseURL: "https://api.example.com") == "https://api.example.com/auth/token")
    }

    @Test("Keeps any other scheme")
    func keepsCustomScheme() throws {
        #expect(try url(baseURL: "ws://localhost:9000") == "ws://localhost:9000/auth/token")
    }

    @Test("Falls back to https when the base URL has no scheme")
    func defaultsToHTTPS() throws {
        #expect(try url(baseURL: "//api.example.com") == "https://api.example.com/auth/token")
    }
}
