#if canImport(CryptoKit)
import ClewCore
import ClewStore
@testable import ClewGateway
import Foundation
import Testing

/// `Contract/v1/*.json` is shared with the extension's tests (Contract/v1/README.md).
@Suite struct ContractTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Contract/v1")

    /// Decodes the example, re-encodes it, and checks nothing was lost or renamed.
    private func roundTrips<T: Codable>(_ type: T.Type, _ file: String) throws {
        let data = try Data(contentsOf: Self.directory.appendingPathComponent(file))
        let value = try JSONDecoder().decode(type, from: data)
        let again = try JSONEncoder().encode(value)
        let original = try JSONSerialization.jsonObject(with: data) as! NSDictionary
        let reencoded = try JSONSerialization.jsonObject(with: again) as! NSDictionary
        #expect(original == reencoded, "\(file)")
    }

    @Test func everyExampleMatchesTheSwiftTypes() throws {
        try roundTrips(API.Hello.self, "hello.response.json")
        try roundTrips(API.PairRequest.self, "pair.request.json")
        try roundTrips(API.PairResponse.self, "pair.response.json")
        try roundTrips(API.ImportRequest.self, "import.request.json")
        try roundTrips(API.ImportResponse.self, "import.response.json")
        try roundTrips(API.ImportRequest.self, "import-x.request.json")
        try roundTrips(API.ImportResponse.self, "import-x.response.json")
        try roundTrips(API.ImportRequest.self, "import-x-end.request.json")
        try roundTrips(API.ImportResponse.self, "import-x-end.response.json")
        try roundTrips(API.BookmarkRequest.self, "bookmark.request.json")
        try roundTrips(API.BookmarkResponse.self, "bookmark.response.json")
        try roundTrips(API.Failure.self, "failure.response.json")
    }

    @Test func helloProofMatchesAFixedVector() {
        // The extension's contract test checks the same value (from Python's hmac).
        #expect(Crypto.hmac(secret: "c2VjcmV0", message: "abcdefghijklmnop") == "khZw39NRSnJr9gReScOR4gC1Ho_Nev73PUGL2JjG0V0")
    }

    @Test(arguments: [("/v1/import", "import"), ("/v1/import", "import-x"), ("/v1/import", "import-x-end"),
                      ("/v1/bookmark", "bookmark")])
    func eachRequestExampleGetsItsResponseExample(path: String, name: String) throws {
        // The response example is the real answer to the request example, from a new Clew.
        let now = Now()
        let clew = Clew(store: try SQLiteStore.inMemory(), clock: SystemClockForTests(source: now), zones: UTCZone())
        let credentials = MemoryCredentials()
        let gateway = try Gateway(clew: clew, credentials: credentials, allowedOrigins: [])
        gateway.listening(on: 39271)
        gateway.startPairing()
        let code = try #require(gateway.pendingPairing?.code)
        let pairing = gateway.handle(HTTPRequest(method: "POST", path: "/v1/pair",
            headers: ["host": "127.0.0.1:39271", "content-type": "application/json"],
            body: try JSONEncoder().encode(API.PairRequest(code: code, name: "contract"))))
        let token = try JSONDecoder().decode(API.PairResponse.self, from: pairing.body).token
        let response = gateway.handle(HTTPRequest(method: "POST", path: path,
            headers: ["host": "127.0.0.1:39271", "content-type": "application/json", "authorization": "Bearer \(token)"],
            body: try Data(contentsOf: Self.directory.appendingPathComponent("\(name).request.json"))))
        let expected = try JSONSerialization.jsonObject(
            with: Data(contentsOf: Self.directory.appendingPathComponent("\(name).response.json"))) as! NSDictionary
        #expect(response.status == 200)
        #expect(try JSONSerialization.jsonObject(with: response.body) as! NSDictionary == expected)
    }
}
#endif
