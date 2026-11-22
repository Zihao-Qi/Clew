import AppKit
import ClewAI
import CryptoKit
import Foundation
import Network
import Security

/// What only Apple's frameworks can do for ClewAI (docs/AGENT.md §2): the network, the
/// Keychain, the browser's loopback callback, hashing and the ID token's signature.

/// URLSession, ephemeral: no cache, no cookies.
struct URLSessionTransport: HTTPTransport {
    static let session = URLSession(configuration: .ephemeral)

    private func urlRequest(_ r: HTTPRequest) -> URLRequest {
        var u = URLRequest(url: r.url, timeoutInterval: r.timeout)
        u.httpMethod = r.method
        u.httpBody = r.body
        for (k, v) in r.headers { u.setValue(v, forHTTPHeaderField: k) }
        return u
    }

    private static func headers(_ response: URLResponse) -> (Int, [String: String]) {
        let http = response as? HTTPURLResponse
        var out: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] { out["\(k)"] = "\(v)" }
        return (http?.statusCode ?? 0, out)
    }

    static func mapped(_ error: Error) -> Error {
        guard let url = error as? URLError else { return error }
        switch url.code {
        case .cancelled: return CancellationError()
        case .timedOut: return TransportError.timedOut
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            return TransportError.offline
        default: return TransportError.other("url_\(url.code.rawValue)")
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await Self.session.data(for: urlRequest(request))
            let (status, headers) = Self.headers(response)
            return HTTPResponse(status: status, headers: headers, body: data)
        } catch { throw Self.mapped(error) }
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await Self.session.bytes(for: urlRequest(request)) } catch { throw Self.mapped(error) }
        let (status, headers) = Self.headers(response)
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch { continuation.finish(throwing: Self.mapped(error)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStream(status: status, headers: headers, lines: lines)
    }
}

/// The sign-in's tokens in the login Keychain, this Mac only, never synced
/// (docs/AGENT.md §3): never in Clew's data, its backups or an export.
struct KeychainSession: SessionStore {
    static let service = "io.github.zihao-qi.clew.chatgpt"
    var account = "session"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    func load() throws -> ChatGPTSession? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainCredentials.KeychainError(status: status) }
        return try? JSONDecoder().decode(ChatGPTSession.self, from: data)
    }

    func save(_ session: ChatGPTSession) throws {
        let data = try JSONEncoder().encode(session)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Clew ChatGPT sign-in"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainCredentials.KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainCredentials.KeychainError(status: status)
        }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentials.KeychainError(status: status)
        }
    }
}

enum AICrypto {
    static func random(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// RS256: the ID token's signature against OpenAI's key with its `kid`.
    static func verify(_ token: IDToken, keys: [SigningKey]) -> Bool {
        guard let key = keys.first(where: { $0.keyId == token.keyId }) ?? (token.keyId == nil && keys.count == 1 ? keys.first : nil),
              let secKey = SecKeyCreateWithData(key.der as CFData, [
                  kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                  kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
              ] as CFDictionary, nil) else { return false }
        return SecKeyVerifySignature(secKey, .rsaSignatureMessagePKCS1v15SHA256, token.signingInput as CFData,
                                     token.signature as CFData, nil)
    }
}

/// Listens on 127.0.0.1 for the browser's callback, only while signing in: 1455, or the
/// next free port if another app holds it (docs/AGENT.md §3).
@MainActor
final class LoopbackCallback {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var received: [String: String]?
    private(set) var port: UInt16 = 0

    struct Failure: Error {}

    /// Resumes once: the listener became ready, or it could not.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ c: CheckedContinuation<Bool, Never>) { continuation = c }
        func resume(_ ok: Bool) {
            let c = lock.withLock { () -> CheckedContinuation<Bool, Never>? in defer { continuation = nil }; return continuation }
            c?.resume(returning: ok)
        }
    }

    /// Binds the first free port from 1455 on and starts listening.
    func bind() async throws {
        for candidate in UInt16(1455)...1465 {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: candidate)!)
            guard let listener = try? NWListener(using: parameters) else { continue }
            listener.newConnectionHandler = { [weak self] connection in Self.answer(connection) { values in
                Task { @MainActor in self?.finish(.success(values)) }
            } }
            let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                let once = Once(c)
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: once.resume(true)
                    case .failed, .cancelled:
                        once.resume(false)
                        Task { @MainActor in self?.listenerFailed(listener) }
                    default: break
                    }
                }
                listener.start(queue: .main)
            }
            if ok {
                self.listener = listener
                port = candidate
                return
            }
            listener.cancel()
        }
        throw Failure()
    }

    /// A listener in use that fails ends the wait; one that never bound is just dropped.
    private func listenerFailed(_ failed: NWListener) {
        guard failed === listener else { return }
        finish(.failure(Failure()))
    }

    /// Answers the browser and hands back the callback's query; anything else is a 404.
    nonisolated private static func answer(_ connection: NWConnection, _ done: @escaping @Sendable ([String: String]) -> Void) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard request.hasPrefix("GET "), target.hasPrefix("/auth/callback"),
                  let parts = URLComponents(string: "http://127.0.0.1" + target) else {
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            var values: [String: String] = [:]
            for item in parts.queryItems ?? [] { values[item.name] = item.value ?? "" }
            let page = String(localized: "You can close this tab and go back to Clew.")
            let body = "<!doctype html><meta charset=utf-8><title>Clew</title><body style='font:15px -apple-system;margin:3em'>\(page)</body>"
            connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
            done(values)
        }
    }

    /// The callback's query, once the browser comes back; `stop()` ends the wait.
    func wait() async throws -> [String: String] {
        if let received { return received }
        guard listener != nil else { throw Failure() }
        return try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        if case .success(let values) = result, received == nil { received = values }
        listener?.cancel()
        listener = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }
}
