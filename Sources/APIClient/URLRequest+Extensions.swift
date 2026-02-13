import Foundation

extension URLRequest {
    var method: HTTPMethod? {
        return HTTPMethod(rawValue: httpMethod)
    }

    public var curlString: String {
        var parts = ["curl -v"]

        if let method = httpMethod, method != "GET" {
            parts.append("-X \(method)")
        }

        if let headers = allHTTPHeaderFields {
            for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
                parts.append("-H '\(key): \(value)'")
            }
        }

        if let body = httpBody, let bodyString = String(data: body, encoding: .utf8) {
            let escaped = bodyString.replacingOccurrences(of: "'", with: "'\\''")
            parts.append("-d '\(escaped)'")
        }

        if let url = url?.absoluteString {
            parts.append("'\(url)'")
        }

        return parts.joined(separator: " \\\n  ")
    }
}
