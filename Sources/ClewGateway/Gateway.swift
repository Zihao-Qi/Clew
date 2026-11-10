#if canImport(CryptoKit)
import ClewCore
import ClewDomain
import Foundation

/// The last scan a client sent, for Settings ("Watch Later: 12 videos · 2 min ago")
/// and for "YouTube import needs an update".
public struct ImportReport: Hashable, Sendable {
    public var at: Date
    public var source: Source
    public var listTotal: Int?
    public var scan: ScanReport
    public var result: ImportResult
    public var needsUpdate: Bool
}

/// The local API (ARCHITECTURE §6, v1.1): request handling only. The app's listener
/// feeds it requests from `127.0.0.1`. Every write goes through `Clew` commands.
public final class Gateway: @unchecked Sendable {
    /// Clients probe these for `GET /v1/hello`; Clew listens on the first free one.
    public static let ports: ClosedRange<UInt16> = 39271...39275
    public static let pairingLifetime: TimeInterval = 300
    public static let pairingAttempts = 5
    public static let maxClientNameLength = 40

    private var currentClew: Clew?
    private let credentials: any CredentialStore
    private let now: @Sendable () -> Date
    private let allowedOrigins: Set<String>
    private let lock = NSLock()
    /// Held for the whole of an import, and by `use(_:)`: swapping the command layer
    /// waits for an import already running against the old one (restore, AppModel).
    private let importLock = NSLock()
    private var port: UInt16 = 0
    private var pairing: (code: String, expiresAt: Date, attemptsLeft: Int)?
    private var paired: [PairedClient]
    private var reports: [Source: ImportReport] = [:]
    private let changed: @Sendable () -> Void

    /// `onChange` runs (on the caller's thread) after a pairing, a revoke or an import.
    public init(clew: Clew, credentials: any CredentialStore, allowedOrigins: Set<String>,
                now: @escaping @Sendable () -> Date = { Date() }, onChange: @escaping @Sendable () -> Void = {}) throws {
        self.currentClew = clew
        self.credentials = credentials
        self.allowedOrigins = allowedOrigins
        self.now = now
        self.changed = onChange
        self.paired = try credentials.load()
    }

    // MARK: State for the app

    public func listening(on port: UInt16) { lock.withLock { self.port = port } }

    /// Swaps the command layer, e.g. around a restore (nil while the database is closed:
    /// imports are answered with 503 and the client retries later). Returns only after
    /// any import still running against the old one has finished.
    public func use(_ clew: Clew?) {
        importLock.withLock { lock.withLock { currentClew = clew } }
    }
    private var clew: Clew? { lock.withLock { currentClew } }
    public var listeningPort: UInt16 { lock.withLock { port } }

    /// Shows a new 6-digit code in Settings, valid for 5 minutes and 5 tries.
    @discardableResult
    public func startPairing() -> (code: String, expiresAt: Date) {
        var g = SystemRandomNumberGenerator()
        let code = String(format: "%06d", Int.random(in: 0...999_999, using: &g))
        let expiresAt = now().addingTimeInterval(Self.pairingLifetime)
        lock.withLock { pairing = (code, expiresAt, Self.pairingAttempts) }
        return (code, expiresAt)
    }

    public func cancelPairing() { lock.withLock { pairing = nil } }

    /// The code being shown, if one is still valid.
    public var pendingPairing: (code: String, expiresAt: Date)? {
        lock.withLock {
            guard let p = pairing, p.expiresAt > now() else { return nil }
            return (p.code, p.expiresAt)
        }
    }

    public var clients: [PairedClient] { lock.withLock { paired } }

    public func revoke(_ id: UUID) throws {
        try lock.withLock {
            let remaining = paired.filter { $0.id != id }
            try credentials.save(remaining)
            paired = remaining
        }
        changed()
    }

    public func lastImport(from source: Source) -> ImportReport? { lock.withLock { reports[source] } }

    // MARK: Requests

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        // DNS rebinding: a web page that resolved its own name to 127.0.0.1 still sends
        // its own Host.
        guard request.headers["host"] == "127.0.0.1:\(listeningPort)" else { return failure(421, "wrong host") }
        let origin = request.headers["origin"]
        if let origin, !allowedOrigins.contains(origin) { return failure(403, "origin not allowed") }
        var cors: [(String, String)] = []
        if let origin { cors = [("Access-Control-Allow-Origin", origin), ("Vary", "Origin")] }

        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204, headers: cors + [
                ("Access-Control-Allow-Methods", "GET, POST"),
                ("Access-Control-Allow-Headers", "Authorization, Content-Type"),
                ("Access-Control-Max-Age", "600"),
            ])
        }

        var response: HTTPResponse
        switch (request.method, request.path) {
        case ("GET", "/v1/hello"): response = hello(request)
        case ("POST", "/v1/pair"): response = pair(request)
        case ("POST", "/v1/import"): response = importList(request)
        case ("POST", "/v1/bookmark"): response = bookmark(request)
        case (_, "/v1/hello"), (_, "/v1/pair"), (_, "/v1/import"), (_, "/v1/bookmark"):
            response = failure(405, "method not allowed")
        default: response = failure(404, "not found")
        }
        response.headers += cors
        return response
    }

    private func hello(_ request: HTTPRequest) -> HTTPResponse {
        guard let nonce = request.query["nonce"], Self.isNonce(nonce) else { return failure(400, "nonce required") }
        var proof: String?
        if let raw = request.query["client"], let id = UUID(uuidString: raw),
           let client = clients.first(where: { $0.id == id }) {
            proof = Crypto.hmac(secret: client.secret, message: nonce)
        }
        return json(200, API.Hello(app: "clew", api: API.version, proof: proof))
    }

    private func pair(_ request: HTTPRequest) -> HTTPResponse {
        guard isJSON(request) else { return failure(415, "JSON only") }
        guard let body = try? JSONDecoder().decode(API.PairRequest.self, from: request.body) else {
            return failure(400, "bad request")
        }
        enum Outcome { case noPairing, wrong, locked, ok }
        let outcome: Outcome = lock.withLock {
            guard let p = pairing, p.expiresAt > now() else { pairing = nil; return .noPairing }
            if Crypto.equal(p.code, body.code) { pairing = nil; return .ok }
            let left = p.attemptsLeft - 1
            pairing = left > 0 ? (p.code, p.expiresAt, left) : nil
            return left > 0 ? .wrong : .locked
        }
        switch outcome {
        case .noPairing: return failure(409, "no pairing in progress")
        case .wrong: return failure(403, "wrong code")
        case .locked: return failure(429, "too many tries; start pairing again")
        case .ok: break
        }
        let token = Crypto.randomBytes(32).base64URL
        let name = String(body.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxClientNameLength))
        let client = PairedClient(
            id: UUID(), name: name.isEmpty ? "Browser" : name, tokenHash: Crypto.sha256Hex(token),
            secret: Crypto.randomBytes(32).base64URL, scopes: [.import], pairedAt: now()
        )
        do {
            try lock.withLock {
                try credentials.save(paired + [client])
                paired.append(client)
            }
        } catch {
            return failure(500, "could not store the pairing")
        }
        changed()
        return json(200, API.PairResponse(clientId: client.id, token: token, secret: client.secret,
                                          scopes: client.scopes.sorted { $0.rawValue < $1.rawValue }))
    }

    private func importList(_ request: HTTPRequest) -> HTTPResponse {
        if let denied = authorize(request, .import) { return denied }
        guard isJSON(request) else { return failure(415, "JSON only") }
        guard let body = try? JSONDecoder().decode(API.ImportRequest.self, from: request.body) else {
            return failure(400, "bad request")
        }
        let response: HTTPResponse = importLock.withLock {
            guard let clew else { return failure(503, "Clew is busy; try again") }
            do {
                let result = try clew.importExternal(ImportBatch(source: body.source, entries: body.entries,
                                                                 listTotal: body.listTotal, scan: body.scan,
                                                                 fromTop: body.fromTop))
                let needsUpdate = body.scan.needsUpdate(listTotal: body.listTotal, result: result)
                let report = ImportReport(at: now(), source: body.source, listTotal: body.listTotal, scan: body.scan,
                                          result: result, needsUpdate: needsUpdate)
                lock.withLock { reports[body.source] = report }
                return json(200, API.ImportResponse(result: result, needsUpdate: needsUpdate,
                                                    listCount: (try? clew.collections().first { $0.source == body.source }?.onList) ?? 0))
            } catch {
                return importFailure(error)
            }
        }
        if response.status == 200 { changed() }
        return response
    }

    private func bookmark(_ request: HTTPRequest) -> HTTPResponse {
        if let denied = authorize(request, .import) { return denied }
        guard isJSON(request) else { return failure(415, "JSON only") }
        guard let body = try? JSONDecoder().decode(API.BookmarkRequest.self, from: request.body) else {
            return failure(400, "bad request")
        }
        let response: HTTPResponse = importLock.withLock {
            guard let clew else { return failure(503, "Clew is busy; try again") }
            do {
                let result = try clew.bookmarkChanged(source: body.source, entry: body.entry, bookmarked: body.bookmarked)
                return json(200, API.BookmarkResponse(
                    result: result, listCount: (try? clew.collections().first { $0.source == body.source }?.onList) ?? 0))
            } catch {
                return importFailure(error)
            }
        }
        if response.status == 200 { changed() }
        return response
    }

    private func importFailure(_ error: any Error) -> HTTPResponse {
        switch error {
        case ClewError.notAllowed:
            failure(400, "source not importable")
        case ClewError.listTurnedOff:
            // The extension tells the user where to turn it back on.
            failure(409, "list turned off in Clew")
        case ClewError.tooManyEntries:
            failure(413, "too many entries")
        default:
            failure(500, "import failed")
        }
    }

    /// Nil when the bearer token belongs to a client with `scope`.
    private func authorize(_ request: HTTPRequest, _ scope: Scope) -> HTTPResponse? {
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else {
            return failure(401, "token required")
        }
        let hash = Crypto.sha256Hex(String(header.dropFirst("Bearer ".count)))
        guard let client = clients.first(where: { Crypto.equal($0.tokenHash, hash) }) else {
            return failure(401, "unknown token")
        }
        return client.scopes.contains(scope) ? nil : failure(403, "scope \(scope.rawValue) required")
    }

    private func isJSON(_ request: HTTPRequest) -> Bool {
        request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true
    }

    /// 16–128 characters of base64url.
    static func isNonce(_ s: String) -> Bool {
        (16...128).contains(s.count) && s.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }

    private func json(_ status: Int, _ value: some Encodable) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(value)) ?? Data()
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: body)
    }

    private func failure(_ status: Int, _ message: String) -> HTTPResponse {
        json(status, API.Failure(error: message))
    }
}
#endif
