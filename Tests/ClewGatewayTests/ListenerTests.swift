#if canImport(Network) && canImport(CryptoKit)
import ClewCore
@testable import ClewGateway
import ClewStore
import Foundation
import Testing

/// Real sockets on 127.0.0.1, on ports away from the app's own range.
@Suite(.serialized) struct ListenerTests {
    private func gateway() throws -> Gateway {
        let clew = Clew(store: try SQLiteStore.inMemory(), clock: SystemClockForTests(source: Now()), zones: UTCZone())
        return try Gateway(clew: clew, credentials: MemoryCredentials(), allowedOrigins: [])
    }

    private func get(_ url: String) async throws -> (Int, Data) {
        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: URL(string: url)!)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    @Test func servesHelloOverLoopback() async throws {
        let listener = GatewayListener(gateway: try gateway(), ports: 49371...49375)
        let port = try await listener.start()
        defer { listener.stop() }
        let (status, data) = try await get("http://127.0.0.1:\(port)/v1/hello?nonce=abcdefghijklmnop")
        #expect(status == 200)
        #expect(try JSONDecoder().decode(API.Hello.self, from: data).app == "clew")
        // `localhost` sends a different Host header and is refused.
        let (refused, _) = try await get("http://localhost:\(port)/v1/hello?nonce=abcdefghijklmnop")
        #expect(refused == 421)
    }

    @Test func fallsBackToTheNextFreePort() async throws {
        let first = GatewayListener(gateway: try gateway(), ports: 49381...49381)
        let taken = try await first.start()
        defer { first.stop() }
        let second = GatewayListener(gateway: try gateway(), ports: 49381...49383)
        let port = try await second.start()
        defer { second.stop() }
        #expect(taken == 49381 && port == 49382)
        let (status, _) = try await get("http://127.0.0.1:\(port)/v1/hello?nonce=abcdefghijklmnop")
        #expect(status == 200)

        let none = GatewayListener(gateway: try gateway(), ports: 49381...49381)
        await #expect(throws: GatewayListener.Failure.noFreePort) { try await none.start() }
    }
}
#endif
