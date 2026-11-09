#if canImport(CryptoKit)
import CryptoKit
import Foundation

/// A paired client (the Chrome extension, later `clew-mcp`). Only a hash of its
/// token is kept; the secret is kept because Clew signs `hello` proofs with it.
public struct PairedClient: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var tokenHash: String
    public var secret: String
    public var scopes: Set<Scope>
    public var pairedAt: Date

    public init(id: UUID, name: String, tokenHash: String, secret: String, scopes: Set<Scope>, pairedAt: Date) {
        self.id = id
        self.name = name
        self.tokenHash = tokenHash
        self.secret = secret
        self.scopes = scopes
        self.pairedAt = pairedAt
    }
}

/// Where paired clients are kept: the Keychain in the app, memory in tests. Never the
/// database, so exports and backups never carry them.
public protocol CredentialStore: Sendable {
    func load() throws -> [PairedClient]
    func save(_ clients: [PairedClient]) throws
}

public final class MemoryCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [PairedClient]
    public init(_ clients: [PairedClient] = []) { self.clients = clients }
    public func load() throws -> [PairedClient] { lock.withLock { clients } }
    public func save(_ clients: [PairedClient]) throws { lock.withLock { self.clients = clients } }
}

enum Crypto {
    static func randomBytes(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func hmac(secret: String, message: String) -> String? {
        guard let key = Data(base64URL: secret) else { return nil }
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        return Data(code).base64URL
    }

    /// Compares without stopping at the first difference.
    static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
#endif
