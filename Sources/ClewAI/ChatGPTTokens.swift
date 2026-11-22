import Foundation

/// A signed-in session: everything saved together in the Keychain (docs/AGENT.md §3).
/// Never in files, logs, URLs or the debug log.
public struct ChatGPTSession: Codable, Sendable, Equatable {
    public var clientId: String
    public var endpoints: ChatGPTEndpoints
    public var access: String
    public var refresh: String
    public var idToken: String
    public var expiresAt: Date
    public var scopes: [String]
    /// The account (the ID token's `sub`) and its email.
    public var account: String
    public var email: String?

    public init(clientId: String, endpoints: ChatGPTEndpoints, access: String, refresh: String, idToken: String,
                expiresAt: Date, scopes: [String], account: String, email: String?) {
        self.clientId = clientId
        self.endpoints = endpoints
        self.access = access
        self.refresh = refresh
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.account = account
        self.email = email
    }

    /// A valid ID token alone does not allow plan use; the granted scopes must say so.
    public var hasPlanPermission: Bool { scopes.contains(ChatGPT.planScope) }
}

/// The token endpoint's answer.
public struct TokenAnswer: Sendable, Equatable {
    public var access: String
    public var refresh: String?
    public var idToken: String?
    public var expiresIn: TimeInterval
    public var scopes: [String]?
}

/// An OAuth error from the token or revocation endpoint, by its code.
public struct TokenError: Error, Equatable, Sendable {
    public var code: String
    public var status: Int

    /// Refresh errors that end the sign-in ("Sign in again"); `invalid_client` is a bug.
    public static let ending: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
        "refresh_token_invalidated", "refresh_token_reused",
    ]
    public var endsSignIn: Bool { Self.ending.contains(code) }
}

public enum Tokens {
    /// Reads a token answer. Only the status and the error's code ever leave this function:
    /// the body may hold tokens.
    public static func parse(_ response: HTTPResponse) throws -> TokenAnswer {
        let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        guard response.status == 200 else {
            throw TokenError(code: errorCode(json) ?? "http_\(response.status)", status: response.status)
        }
        guard let json, let access = json["access_token"] as? String, !access.isEmpty else {
            throw TokenError(code: "malformed", status: response.status)
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let scopes = (json["scope"] as? String).map { $0.split(separator: " ").map(String.init) }
        return TokenAnswer(access: access, refresh: json["refresh_token"] as? String,
                           idToken: json["id_token"] as? String, expiresIn: expiresIn, scopes: scopes)
    }

    /// `{"error": "code"}` (OAuth) or `{"error": {"code": …}}`.
    static func errorCode(_ json: [String: Any]?) -> String? {
        if let code = json?["error"] as? String { return code }
        if let error = json?["error"] as? [String: Any] { return error["code"] as? String }
        return nil
    }

    /// A refresh: the issued client id, the refresh token and the resource; no `scope`, so
    /// the grant stays as it is.
    public static func refreshRequest(_ session: ChatGPTSession) -> HTTPRequest {
        .form(session.endpoints.token, [("grant_type", "refresh_token"), ("client_id", session.clientId),
                                        ("refresh_token", session.refresh), ("resource", ChatGPT.api)])
    }

    /// The session after a refresh: the refresh token rotates, so everything is replaced
    /// together. An answer without a new refresh token keeps the old one.
    public static func refreshed(_ session: ChatGPTSession, _ answer: TokenAnswer, now: Date) -> ChatGPTSession {
        var next = session
        next.access = answer.access
        next.refresh = answer.refresh ?? session.refresh
        if let id = answer.idToken { next.idToken = id }
        next.expiresAt = now.addingTimeInterval(answer.expiresIn)
        if let scopes = answer.scopes { next.scopes = scopes }
        return next
    }

    /// Revokes the refresh token (sign out).
    public static func revokeRequest(_ session: ChatGPTSession) -> HTTPRequest {
        .form(session.endpoints.revocation, [("token", session.refresh), ("token_type_hint", "refresh_token"),
                                             ("client_id", session.clientId)])
    }
}

/// The ID token: a JWT whose signature the app checks against OpenAI's keys (RS256),
/// and whose claims are checked here.
public struct IDToken: Sendable, Equatable {
    public var keyId: String?
    public var algorithm: String
    /// `header.payload`, what the signature covers.
    public var signingInput: Data
    public var signature: Data
    public var issuer: String?
    public var audience: [String]
    public var expires: Date?
    public var nonce: String?
    public var subject: String?
    public var email: String?

    public init(_ token: String) throws {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerData = base64urlDecode(parts[0]), let payloadData = base64urlDecode(parts[1]),
              let signature = base64urlDecode(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw SignInError.idToken("malformed")
        }
        keyId = header["kid"] as? String
        algorithm = header["alg"] as? String ?? ""
        signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        self.signature = signature
        issuer = claims["iss"] as? String
        if let one = claims["aud"] as? String { audience = [one] } else { audience = claims["aud"] as? [String] ?? [] }
        expires = (claims["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        nonce = claims["nonce"] as? String
        subject = claims["sub"] as? String
        email = claims["email"] as? String
    }

    /// Issuer, audience (the issued client id), expiry and nonce. The signature is checked
    /// separately (`verify`), so a token is used only after both.
    public func checkClaims(clientId: String, nonce expected: String?, now: Date) throws {
        guard algorithm == "RS256" else { throw SignInError.idToken("alg") }
        guard issuer == ChatGPT.issuer else { throw SignInError.idToken("iss") }
        guard audience.contains(clientId) else { throw SignInError.idToken("aud") }
        guard let expires, expires > now else { throw SignInError.idToken("exp") }
        if let expected { guard nonce == expected else { throw SignInError.idToken("nonce") } }
        guard let subject, !subject.isEmpty else { throw SignInError.idToken("sub") }
    }
}

/// OpenAI's signing keys (JWKS).
public struct SigningKey: Sendable, Equatable {
    public var keyId: String
    /// The RSA modulus and exponent, big-endian.
    public var modulus: Data
    public var exponent: Data

    public static func parse(_ response: HTTPResponse) throws -> [SigningKey] {
        guard response.status == 200, let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let keys = json["keys"] as? [[String: Any]] else { throw SignInError.idToken("jwks") }
        return keys.compactMap { key in
            guard key["kty"] as? String == "RSA", (key["use"] as? String ?? "sig") == "sig",
                  let kid = key["kid"] as? String, let n = (key["n"] as? String).flatMap({ base64urlDecode($0[...]) }),
                  let e = (key["e"] as? String).flatMap({ base64urlDecode($0[...]) }) else { return nil }
            return SigningKey(keyId: kid, modulus: n, exponent: e)
        }
    }

    /// The key as a DER `RSAPublicKey` (SEQUENCE of two INTEGERs), the form Apple's
    /// Security framework reads.
    public var der: Data {
        func length(_ n: Int) -> Data {
            if n < 0x80 { return Data([UInt8(n)]) }
            var bytes: [UInt8] = []
            var v = n
            while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        func integer(_ raw: Data) -> Data {
            var value = Data(raw.drop { $0 == 0 })
            if value.isEmpty { value = Data([0]) }
            if value.first! & 0x80 != 0 { value.insert(0, at: 0) }
            return Data([0x02]) + length(value.count) + value
        }
        let body = integer(modulus) + integer(exponent)
        return Data([0x30]) + length(body.count) + body
    }
}
