import Foundation

/// The small part of HTTP/1.1 the Gateway speaks: one request per connection,
/// `Content-Length` bodies only (no chunked encoding), then the connection closes.
public struct HTTPRequest: Hashable, Sendable {
    public var method: String
    /// Path without the query, e.g. `/v1/hello`.
    public var path: String
    public var query: [String: String]
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:],
                body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    public static let maxHeaderBytes = 16 * 1024
    /// A full Watch Later (5,000 videos) with long titles fits comfortably.
    public static let maxBodyBytes = 4 * 1024 * 1024

    public enum Parse: Equatable, Sendable {
        case incomplete
        case complete(HTTPRequest)
        /// The status to answer with before closing.
        case invalid(Int)
    }

    /// Parses `data` received so far.
    public static func parse(_ data: Data) -> Parse {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else {
            return data.count > maxHeaderBytes ? .invalid(431) : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes,
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8)
        else { return .invalid(431) }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0" else {
            return .invalid(400)
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { return .invalid(400) }
            // A repeated Host, Origin or Content-Length is ambiguous: refuse it.
            guard headers[name] == nil else { return .invalid(400) }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { return .invalid(501) }
        var length = 0
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { return .invalid(400) }
            guard n <= maxBodyBytes else { return .invalid(413) }
            length = n
        }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]

        let target = String(requestLine[1])
        guard target.hasPrefix("/"), let components = URLComponents(string: target) else { return .invalid(400) }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(HTTPRequest(method: String(requestLine[0]), path: components.path, query: query,
                                     headers: headers, body: Data(body)))
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 421: "Misdirected Request"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}
