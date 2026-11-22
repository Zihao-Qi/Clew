import Foundation

/// One HTTP request, as plain values (docs/AGENT.md §2: ClewAI is Foundation only, so it
/// builds on Linux; the app supplies the URLSession transport).
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// Seconds without any answer before the request fails.
    public var timeout: TimeInterval

    public init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil,
                timeout: TimeInterval = 30) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// The form fields of a form-encoded body, for tests and checks.
    public var formFields: [String: String] {
        guard let body, let text = String(data: body, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return fields
    }

    static func form(_ url: URL, _ fields: [(String, String)]) -> HTTPRequest {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        return HTTPRequest(method: "POST", url: url,
                           headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(body.utf8))
    }
}

/// An answer read whole. Header names are lowercased.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }

    /// OpenAI's request id, kept in the debug log (never the body).
    public var requestId: String? { headers["x-request-id"] }
}

/// An answer read line by line (a server-sent event stream).
public struct HTTPStream: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var lines: AsyncThrowingStream<String, Error>

    public init(status: Int, headers: [String: String] = [:], lines: AsyncThrowingStream<String, Error>) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.lines = lines
    }

    public var requestId: String? { headers["x-request-id"] }
}

/// The network, injected so tests feed recorded answers.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    func stream(_ request: HTTPRequest) async throws -> HTTPStream
}

/// A network failure, as the transport reports it.
public enum TransportError: Error, Equatable, Sendable {
    case offline
    case timedOut
    case other(String)
}
