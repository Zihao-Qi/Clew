import ClewAI
import Foundation

/// Recorded answers, by request path, served in order; every request is kept.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    enum Answer {
        case whole(HTTPResponse)
        case lines(Int, [String], headers: [String: String] = [:])
        case fail(Error)
    }
    private let lock = NSLock()
    private var answers: [String: [Answer]] = [:]
    private(set) var requests: [HTTPRequest] = []
    /// Waits before answering a refresh, so two callers can overlap.
    var delay: Duration = .zero

    func on(_ path: String, _ answer: Answer) {
        lock.withLock { answers[path, default: []].append(answer) }
    }
    func onJSON(_ path: String, _ status: Int, _ json: String) {
        on(path, .whole(HTTPResponse(status: status, body: Data(json.utf8))))
    }
    func sent(_ path: String) -> [HTTPRequest] { lock.withLock { requests.filter { $0.url.path.hasSuffix(path) } } }

    private func next(_ request: HTTPRequest) throws -> Answer {
        try lock.withLock {
            requests.append(request)
            let key = answers.keys.first { request.url.path.hasSuffix($0) } ?? ""
            guard var queue = answers[key], !queue.isEmpty else { throw TransportError.other("no answer for \(request.url.path)") }
            let first = queue.removeFirst()
            answers[key] = queue
            return first
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let answer = try next(request)
        if delay > .zero { try await Task.sleep(for: delay) }
        switch answer {
        case .whole(let r): return r
        case .lines(let status, let lines, let headers):
            return HTTPResponse(status: status, headers: headers, body: Data(lines.joined(separator: "\n").utf8))
        case .fail(let e): throw e
        }
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        switch try next(request) {
        case .whole(let r):
            let text = String(decoding: r.body, as: UTF8.self)
            return HTTPStream(status: r.status, headers: r.headers, lines: Self.lines([text]))
        case .lines(let status, let lines, let headers):
            return HTTPStream(status: status, headers: headers, lines: Self.lines(lines))
        case .fail(let e): throw e
        }
    }

    static func lines(_ lines: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in
            for line in lines { c.yield(line) }
            c.finish()
        }
    }
}

final class MemoryStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: ChatGPTSession?
    private(set) var saves = 0
    init(_ session: ChatGPTSession? = nil) { self.session = session }
    func load() throws -> ChatGPTSession? { lock.withLock { session } }
    func save(_ s: ChatGPTSession) throws { lock.withLock { session = s; saves += 1 } }
    func clear() throws { lock.withLock { session = nil } }
}

let endpoints = ChatGPTEndpoints(
    authorization: URL(string: "https://auth.openai.com/api/accounts/authorize")!,
    token: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!,
    revocation: URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!,
    jwks: URL(string: "https://auth.openai.com/.well-known/jwks.json")!)

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func session(expiresIn: TimeInterval = 3600, scopes: [String] = ChatGPT.scopes.split(separator: " ").map(String.init))
    -> ChatGPTSession {
    ChatGPTSession(clientId: "oaiapp_1", endpoints: endpoints, access: "A1", refresh: "R1", idToken: "I1",
                   expiresAt: t0.addingTimeInterval(expiresIn), scopes: scopes, account: "user-1", email: "a@b.c")
}

/// SSE lines for a completed answer.
func completed(_ deltas: [String]) -> [String] {
    deltas.map { #"data: {"type":"response.output_text.delta","delta":\#(json($0))}"# } + ["",
        #"data: {"type":"response.completed","response":{}}"#]
}

func json(_ s: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: [s]), as: UTF8.self).dropFirst().dropLast().description
}

func body(_ r: HTTPRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: r.body ?? Data())) as? [String: Any] ?? [:]
}
