import ClewCore
import ClewDomain
import Foundation

/// Gateway `/v1` wire types. The JSON examples in `Contract/v1/` are the contract:
/// these types and the extension's TypeScript types are both tested against them.
public enum API {
    public static let version = 1

    /// `GET /v1/hello?nonce=…[&client=…]`. `proof` is `HMAC-SHA256(secret, nonce)`,
    /// present only for a known client: Clew proves itself before the client sends
    /// its token (ARCHITECTURE §6).
    public struct Hello: Codable, Hashable, Sendable {
        public var app: String
        public var api: Int
        public var proof: String?
    }

    /// `POST /v1/pair`
    public struct PairRequest: Codable, Hashable, Sendable {
        public var code: String
        public var name: String
    }

    public struct PairResponse: Codable, Hashable, Sendable {
        public var clientId: UUID
        public var token: String
        /// Base64url; the key for `hello` proofs.
        public var secret: String
        public var scopes: [Scope]
    }

    /// `POST /v1/import` (scope `import`)
    public struct ImportRequest: Codable, Hashable, Sendable {
        public var source: Source
        /// The site's own count of the list, if the page shows one.
        public var listTotal: Int?
        public var entries: [ExternalEntry]
        public var scan: ScanReport
    }

    public struct ImportResponse: Codable, Hashable, Sendable {
        public var result: ImportResult
        public var needsUpdate: Bool
        public var laterCount: Int
    }

    public struct Failure: Codable, Hashable, Sendable {
        public var error: String
    }
}

/// What a paired client may do. The agent's `agent-output` scope arrives in v1.2.
public enum Scope: String, Codable, Hashable, Sendable, CaseIterable {
    case read
    case `import`
}
