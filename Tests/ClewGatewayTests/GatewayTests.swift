#if canImport(CryptoKit)
import ClewCore
import ClewDomain
@testable import ClewGateway
import ClewStore
import CryptoKit
import Foundation
import Testing

private let port: UInt16 = 39271
private let extensionOrigin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop"

final class Now: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func get() -> Date { lock.withLock { value } }
    func advance(_ s: TimeInterval) { lock.withLock { value += s } }
}

/// A clock that, once armed, stops the next reader until released.
final class GateClock: ClewDomain.Clock, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let source: Now
    private let lock = NSLock()
    private var armed = false
    init(_ source: Now) { self.source = source }
    func arm() { lock.withLock { armed = true } }
    func now() -> Date {
        let stop = lock.withLock { () -> Bool in defer { armed = false }; return armed }
        if stop { entered.signal(); release.wait() }
        return source.get()
    }
}

struct UTCZone: TimeZoneSource { func current() -> TimeZone { TimeZone(identifier: "UTC")! } }
struct SystemClockForTests: ClewDomain.Clock { let source: Now; func now() -> Date { source.get() } }

@Suite struct GatewayTests {
    let now = Now()
    let credentials = MemoryCredentials()
    let store: SQLiteStore
    let clew: Clew
    let gateway: Gateway

    init() throws {
        store = try SQLiteStore.inMemory()
        let now = self.now
        clew = Clew(store: store, clock: SystemClockForTests(source: now), zones: UTCZone())
        gateway = try Gateway(clew: clew, credentials: credentials, allowedOrigins: [extensionOrigin],
                              now: { now.get() })
        gateway.listening(on: port)
    }

    private func request(_ method: String, _ path: String, query: [String: String] = [:], body: Any? = nil,
                         token: String? = nil, origin: String? = extensionOrigin,
                         host: String = "127.0.0.1:\(port)", contentType: String = "application/json") -> HTTPResponse {
        var headers = ["host": host]
        if let origin { headers["origin"] = origin }
        if let token { headers["authorization"] = "Bearer \(token)" }
        var data = Data()
        if let body {
            data = try! JSONSerialization.data(withJSONObject: body)
            headers["content-type"] = contentType
        }
        return gateway.handle(HTTPRequest(method: method, path: path, query: query, headers: headers, body: data))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ r: HTTPResponse) throws -> T {
        try JSONDecoder().decode(type, from: r.body)
    }

    /// Pairs and returns the client's credentials.
    private func pairClient() throws -> API.PairResponse {
        let code = gateway.startPairing().code
        let r = request("POST", "/v1/pair", body: ["code": code, "name": "Chrome"])
        #expect(r.status == 200)
        return try decode(API.PairResponse.self, r)
    }

    private func importBody(_ refs: [String], total: Int?, found: Int? = nil, parsed: Int? = nil) -> [String: Any] {
        var body: [String: Any] = [
            "source": "extension.youtube",
            "entries": refs.map { ["externalRef": $0, "title": "v \($0)"] },
            "scan": ["found": found ?? refs.count, "parsed": parsed ?? refs.count, "selectorVersion": "t"],
        ]
        if let total { body["listTotal"] = total }
        return body
    }

    // MARK: Host and Origin

    @Test func onlyTheExactLoopbackHostIsServed() {
        let nonce = "abcdefghijklmnop"
        #expect(request("GET", "/v1/hello", query: ["nonce": nonce]).status == 200)
        for host in ["localhost:\(port)", "evil.example", "127.0.0.1:\(port + 1)", "127.0.0.1"] {
            #expect(request("GET", "/v1/hello", query: ["nonce": nonce], host: host).status == 421)
        }
    }

    @Test func foreignOriginsAreRefusedAndTheExtensionGetsCORS() {
        let nonce = "abcdefghijklmnop"
        #expect(request("GET", "/v1/hello", query: ["nonce": nonce], origin: "https://evil.example").status == 403)
        #expect(request("OPTIONS", "/v1/import", origin: "https://evil.example").status == 403)
        let ok = request("GET", "/v1/hello", query: ["nonce": nonce])
        #expect(ok.header("Access-Control-Allow-Origin") == extensionOrigin)
        let pre = request("OPTIONS", "/v1/import")
        #expect(pre.status == 204 && pre.header("Access-Control-Allow-Origin") == extensionOrigin)
        // No Origin (a non-browser client): served, but with no CORS header.
        #expect(request("GET", "/v1/hello", query: ["nonce": nonce], origin: nil).header("Access-Control-Allow-Origin") == nil)
    }

    // MARK: Hello

    @Test func helloProvesClewOnlyToAKnownClient() throws {
        let nonce = "Zm9vYmFyYmF6cXV4MTIzNA"
        #expect(request("GET", "/v1/hello").status == 400)
        #expect(request("GET", "/v1/hello", query: ["nonce": "short"]).status == 400)
        #expect(request("GET", "/v1/hello", query: ["nonce": "abcdefghijklmnop!"]).status == 400)
        let anonymous = try decode(API.Hello.self, request("GET", "/v1/hello", query: ["nonce": nonce]))
        #expect(anonymous == API.Hello(app: "clew", api: 1, proof: nil))

        let paired = try pairClient()
        let hello = try decode(API.Hello.self, request("GET", "/v1/hello",
                                                       query: ["nonce": nonce, "client": paired.clientId.uuidString]))
        // Checked independently: HMAC-SHA256(secret, nonce), base64url.
        let key = SymmetricKey(data: try #require(Data(base64URL: paired.secret)))
        let expected = Data(HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: key)).base64URL
        #expect(hello.proof == expected)
        let other = try decode(API.Hello.self, request("GET", "/v1/hello",
                                                       query: ["nonce": nonce, "client": UUID().uuidString]))
        #expect(other.proof == nil)
    }

    // MARK: Pairing

    @Test func pairingNeedsTheCodeShownInSettings() throws {
        #expect(request("POST", "/v1/pair", body: ["code": "000000", "name": "x"]).status == 409)
        let code = gateway.startPairing().code
        #expect(code.count == 6 && code.allSatisfy(\.isNumber))
        let wrong = code == "000000" ? "000001" : "000000"
        #expect(request("POST", "/v1/pair", body: ["code": wrong, "name": "x"]).status == 403)
        let r = request("POST", "/v1/pair", body: ["code": code, "name": "  Chrome  "])
        #expect(r.status == 200)
        let paired = try decode(API.PairResponse.self, r)
        #expect(paired.scopes == [.import])
        // Single use.
        #expect(request("POST", "/v1/pair", body: ["code": code, "name": "x"]).status == 409)
        // Only the token's hash is kept.
        let stored = try #require(try credentials.load().first)
        #expect(stored.name == "Chrome" && stored.tokenHash != paired.token)
        #expect(stored.tokenHash == Crypto.sha256Hex(paired.token))
        #expect(gateway.pendingPairing == nil)
    }

    @Test func fiveWrongTriesEndThePairing() throws {
        let code = gateway.startPairing().code
        let wrong = code == "000000" ? "000001" : "000000"
        for _ in 1..<Gateway.pairingAttempts {
            #expect(request("POST", "/v1/pair", body: ["code": wrong, "name": "x"]).status == 403)
        }
        #expect(request("POST", "/v1/pair", body: ["code": wrong, "name": "x"]).status == 429)
        #expect(request("POST", "/v1/pair", body: ["code": code, "name": "x"]).status == 409)
        #expect(try credentials.load().isEmpty)
    }

    @Test func aCodeExpiresAfterFiveMinutes() {
        let code = gateway.startPairing().code
        now.advance(Gateway.pairingLifetime - 1)
        #expect(gateway.pendingPairing != nil)
        now.advance(1)
        #expect(gateway.pendingPairing == nil)
        #expect(request("POST", "/v1/pair", body: ["code": code, "name": "x"]).status == 409)
    }

    // MARK: Import

    @Test func importNeedsAValidTokenWithTheImportScope() throws {
        let body = importBody(["aaaaaaaaaaa"], total: 1)
        #expect(request("POST", "/v1/import", body: body).status == 401)
        #expect(request("POST", "/v1/import", body: body, token: "nope").status == 401)
        // A client paired without the import scope.
        try credentials.save([PairedClient(id: UUID(), name: "reader", tokenHash: Crypto.sha256Hex("reader-token"),
                                           secret: "c2VjcmV0", scopes: [.read], pairedAt: now.get())])
        let readOnly = try Gateway(clew: clew, credentials: credentials, allowedOrigins: [extensionOrigin])
        readOnly.listening(on: port)
        let denied = readOnly.handle(HTTPRequest(method: "POST", path: "/v1/import",
            headers: ["host": "127.0.0.1:\(port)", "authorization": "Bearer reader-token", "content-type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body)))
        #expect(denied.status == 403)
        #expect(try clew.collections().isEmpty)   // nothing was imported
    }

    @Test func importAddsToTheCollectionAndReportsHealth() throws {
        let paired = try pairClient()
        let r = request("POST", "/v1/import", body: importBody(["aaaaaaaaaaa", "bbbbbbbbbbb"], total: 2),
                        token: paired.token)
        #expect(r.status == 200)
        let response = try decode(API.ImportResponse.self, r)
        #expect(response.result.added == 2 && response.listCount == 2 && !response.needsUpdate)
        #expect(gateway.lastImport(from: .extensionYouTube)?.result.added == 2)
        // listCount is what is on the list, ticked or not.
        try clew.checkIn(itemId: try #require(try clew.collection(.extensionYouTube)?.notStarted.first).id)
        let again = try decode(API.ImportResponse.self, request(
            "POST", "/v1/import", body: importBody(["aaaaaaaaaaa", "bbbbbbbbbbb"], total: 2), token: paired.token))
        #expect(again.listCount == 2)

        // The page said 12 videos but nothing could be read: flagged, nothing removed.
        let broken = try decode(API.ImportResponse.self, request(
            "POST", "/v1/import", body: importBody([], total: 12, found: 0, parsed: 0), token: paired.token))
        #expect(broken.needsUpdate && broken.result.letGo == 0 && broken.listCount == 2)
        #expect(gateway.lastImport(from: .extensionYouTube)?.needsUpdate == true)
    }

    @Test func importRefusesBadRequests() throws {
        let paired = try pairClient()
        #expect(request("POST", "/v1/import", body: importBody(["aaaaaaaaaaa"], total: 1), token: paired.token,
                        contentType: "text/plain").status == 415)
        var userSource = importBody(["aaaaaaaaaaa"], total: 1)
        userSource["source"] = "user"
        #expect(request("POST", "/v1/import", body: userSource, token: paired.token).status == 400)
        #expect(request("POST", "/v1/import", body: ["entries": 3], token: paired.token).status == 400)
        #expect(request("GET", "/v1/import", token: paired.token).status == 405)
        #expect(request("GET", "/v1/items").status == 404)
        #expect(try clew.collections().isEmpty)   // nothing was imported
    }

    @Test func aListTurnedOffInClewIsRefusedWithItsOwnStatus() throws {
        let paired = try pairClient()
        try clew.setCollection(.extensionYouTube, on: false)
        let r = request("POST", "/v1/import", body: importBody(["aaaaaaaaaaa"], total: 1), token: paired.token)
        #expect(r.status == 409)   // the extension says where to turn it back on
        #expect(try decode(API.Failure.self, r).error == "list turned off in Clew")
        #expect(try clew.collectionsOff() == [.extensionYouTube])
        try clew.setCollection(.extensionYouTube, on: true)
        #expect(try clew.collections().isEmpty)   // nothing was imported while it was off
    }

    @Test func theBookmarkButtonNeedsATokenAndAnXPost() throws {
        let paired = try pairClient()
        let click: [String: Any] = ["source": "extension.x", "bookmarked": true,
                                    "entry": ["externalRef": "1850000000000000001", "title": "a post"]]
        #expect(request("POST", "/v1/bookmark", body: click).status == 401)
        #expect(request("POST", "/v1/bookmark", body: click, token: paired.token, contentType: "text/plain").status == 415)
        #expect(request("GET", "/v1/bookmark", token: paired.token).status == 405)
        var youTube = click
        youTube["source"] = "extension.youtube"
        #expect(request("POST", "/v1/bookmark", body: youTube, token: paired.token).status == 400)
        try clew.setCollection(.extensionX, on: false)
        #expect(request("POST", "/v1/bookmark", body: click, token: paired.token).status == 409)
        try clew.setCollection(.extensionX, on: true)
        #expect(try clew.collections().isEmpty)    // nothing was added
        let r = request("POST", "/v1/bookmark", body: click, token: paired.token)
        #expect(r.status == 200)
        #expect(try decode(API.BookmarkResponse.self, r).listCount == 1)
    }

    @Test func aRevokedClientIsLockedOut() throws {
        let paired = try pairClient()
        try gateway.revoke(paired.clientId)
        #expect(request("POST", "/v1/import", body: importBody(["aaaaaaaaaaa"], total: 1), token: paired.token).status == 401)
        #expect(try credentials.load().isEmpty)
        let hello = try decode(API.Hello.self, request("GET", "/v1/hello",
                                                       query: ["nonce": "abcdefghijklmnop", "client": paired.clientId.uuidString]))
        #expect(hello.proof == nil)
    }

    @Test func swappingTheDatabaseWaitsForARunningImport() throws {
        let paired = try pairClient()
        let gate = GateClock(Now())
        gateway.use(Clew(store: store, clock: gate, zones: UTCZone()))
        let body = try JSONSerialization.data(withJSONObject: importBody(["aaaaaaaaaaa"], total: 1))
        let req = HTTPRequest(method: "POST", path: "/v1/import", headers: [
            "host": "127.0.0.1:\(port)", "authorization": "Bearer \(paired.token)", "content-type": "application/json",
        ], body: body)
        let gateway = self.gateway
        gate.arm()
        let imported = DispatchSemaphore(value: 0), swapped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = gateway.handle(req); imported.signal() }
        defer { gate.release.signal() }                         // never leave the import stuck
        // The import is inside Clew now (bounded, so a broken Gateway fails, not hangs).
        try #require(gate.entered.wait(timeout: .now() + 5) == .success)
        DispatchQueue.global().async { gateway.use(nil); swapped.signal() }
        #expect(swapped.wait(timeout: .now() + 0.3) == .timedOut)   // the swap waits for it
        gate.release.signal()
        #expect(imported.wait(timeout: .now() + 5) == .success)
        #expect(swapped.wait(timeout: .now() + 5) == .success)
    }

    @Test func importsAreRefusedWhileTheDatabaseIsClosed() throws {
        let paired = try pairClient()
        gateway.use(nil)
        #expect(request("POST", "/v1/import", body: importBody(["aaaaaaaaaaa"], total: 1), token: paired.token).status == 503)
        gateway.use(clew)
        #expect(request("POST", "/v1/import", body: importBody(["aaaaaaaaaaa"], total: 1), token: paired.token).status == 200)
    }

    @Test func pairedClientsSurviveARestart() throws {
        let paired = try pairClient()
        let restarted = try Gateway(clew: clew, credentials: credentials, allowedOrigins: [extensionOrigin])
        restarted.listening(on: port)
        let r = restarted.handle(HTTPRequest(method: "POST", path: "/v1/import",
            headers: ["host": "127.0.0.1:\(port)", "authorization": "Bearer \(paired.token)", "content-type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: importBody(["aaaaaaaaaaa"], total: 1))))
        #expect(r.status == 200)
    }
}

@Suite struct HTTPParseTests {
    private func parse(_ s: String) -> HTTPRequest.Parse { HTTPRequest.parse(Data(s.utf8)) }

    @Test func parsesARequestOnceItsBodyHasArrived() throws {
        let head = "POST /v1/import?a=1&b=two HTTP/1.1\r\nHost: 127.0.0.1:39271\r\nContent-Length: 4\r\n\r\n"
        #expect(parse("POST /v1/import HTTP/1.1\r\nHost: x") == .incomplete)
        #expect(parse(head + "ab") == .incomplete)
        guard case .complete(let r) = parse(head + "abcd") else { Issue.record("not parsed"); return }
        #expect(r.method == "POST" && r.path == "/v1/import" && r.query == ["a": "1", "b": "two"])
        #expect(r.headers["host"] == "127.0.0.1:39271" && r.body == Data("abcd".utf8))
    }

    @Test func refusesWhatItDoesNotSpeak() {
        #expect(parse("GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") == .invalid(501))
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n") == .invalid(400))
        #expect(parse("GET / HTTP/1.1\r\nContent-Length: \(HTTPRequest.maxBodyBytes + 1)\r\n\r\n") == .invalid(413))
        #expect(parse("GET / HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == .invalid(400))
        #expect(parse("GET /\r\n\r\n") == .invalid(400))
        #expect(parse("GET http://evil/ HTTP/1.1\r\n\r\n") == .invalid(400))
        #expect(parse("GET / HTTP/1.1\r\nX-Big: " + String(repeating: "a", count: HTTPRequest.maxHeaderBytes)) == .invalid(431))
    }
}
#endif
