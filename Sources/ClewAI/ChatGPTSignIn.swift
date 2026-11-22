import Foundation

/// OpenAI's Sign in with ChatGPT for open-source, locally run apps (docs/AGENT.md §3),
/// as plain rules. The app supplies randomness, SHA-256, the browser, the loopback
/// listener and the ID token's signature check.
public enum ChatGPT {
    public static let issuer = "https://auth.openai.com"
    public static let discovery = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    public static let api = "https://api.openai.com/v1"
    public static let agentName = "Clew"
    public static let firstClientId = "dynamic_agent_client"
    public static let planScope = "chatgpt.tokens.use.direct"
    public static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    public static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    /// The loopback callback's path; only the port may vary (never `localhost`).
    public static func redirect(port: UInt16) -> String { "http://127.0.0.1:\(port)/auth/callback" }
}

/// The endpoints, read from OpenAI's OpenID configuration.
public struct ChatGPTEndpoints: Codable, Sendable, Equatable {
    public var authorization: URL
    public var token: URL
    public var revocation: URL
    public var jwks: URL

    public init(authorization: URL, token: URL, revocation: URL, jwks: URL) {
        self.authorization = authorization
        self.token = token
        self.revocation = revocation
        self.jwks = jwks
    }

    public static var discoveryRequest: HTTPRequest { HTTPRequest(url: ChatGPT.discovery) }

    /// Refuses a configuration for another issuer or with an endpoint off auth.openai.com.
    public static func parse(_ response: HTTPResponse) throws -> ChatGPTEndpoints {
        guard response.status == 200,
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              json["issuer"] as? String == ChatGPT.issuer else { throw SignInError.discovery }
        func url(_ key: String) throws -> URL {
            guard let text = json[key] as? String, let url = URL(string: text), url.scheme == "https",
                  url.host == "auth.openai.com" else { throw SignInError.discovery }
            return url
        }
        return ChatGPTEndpoints(authorization: try url("authorization_endpoint"), token: try url("token_endpoint"),
                                revocation: try url("revocation_endpoint"), jwks: try url("jwks_uri"))
    }
}

public enum SignInError: Error, Equatable, Sendable {
    case discovery
    /// The person said no in the browser (`access_denied`).
    case denied
    case stateMismatch
    case noCode
    /// The callback carried no issued client id on a first sign-in.
    case noClientId
    /// The callback's client id is not the one Clew was issued before.
    case clientIdChanged
    /// The code could not be exchanged (`invalid_grant`): start again.
    case invalidGrant
    case exchange(String)
    case idToken(String)
    /// Any other error the callback named.
    case callback(String)
}

/// One sign-in attempt: fresh PKCE verifier, state and nonce (docs/AGENT.md §3).
public struct SignInAttempt: Sendable, Equatable {
    public var verifier: String
    public var challenge: String
    public var state: String
    public var nonce: String
    public var redirect: String

    /// `random` gives URL-safe random text; `sha256` hashes (the app's CryptoKit).
    public init(port: UInt16, random: (Int) -> String, sha256: (Data) -> Data) {
        verifier = random(32)
        challenge = base64url(sha256(Data(verifier.utf8)))
        state = random(16)
        nonce = random(16)
        redirect = ChatGPT.redirect(port: port)
    }

    /// The browser's address. A first sign-in (no client id kept) registers as Clew; a later
    /// one uses the issued id and, unless the person signed out, the last ID token as a hint.
    /// `consent` asks again for a permission the person declined.
    public func authorizeURL(_ endpoints: ChatGPTEndpoints, clientId: String?, hostId: String,
                             idTokenHint: String? = nil, consent: Bool = false) -> URL {
        var parts = URLComponents(url: endpoints.authorization, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: clientId ?? ChatGPT.firstClientId),
            URLQueryItem(name: "ext_agent_host_id", value: hostId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: ChatGPT.scopes),
            URLQueryItem(name: "resource", value: ChatGPT.api),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]
        if clientId == nil { items.append(URLQueryItem(name: "agent_name_hint", value: ChatGPT.agentName)) }
        if let idTokenHint, clientId != nil { items.append(URLQueryItem(name: "id_token_hint", value: idTokenHint)) }
        if consent { items.append(URLQueryItem(name: "prompt", value: "consent")) }
        parts.queryItems = items
        // `+` in a query is read as a space by some servers; spell it out.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }

    /// Reads the browser's callback: the state first, then a refusal, then the code and the
    /// issued client id (which must match the kept one, if any).
    public func callback(_ query: [String: String], keptClientId: String?) throws -> (code: String, clientId: String) {
        guard query["state"] == state else { throw SignInError.stateMismatch }
        if let error = query["error"] {
            throw error == "access_denied" ? SignInError.denied : SignInError.callback(error)
        }
        guard let code = query["code"], !code.isEmpty else { throw SignInError.noCode }
        let issued = query["client_id"].flatMap { $0.isEmpty ? nil : $0 }
        if let keptClientId {
            if let issued, issued != keptClientId { throw SignInError.clientIdChanged }
            return (code, keptClientId)
        }
        guard let issued, issued != ChatGPT.firstClientId else { throw SignInError.noClientId }
        return (code, issued)
    }

    /// The code for tokens (form-encoded; no client secret).
    public func exchange(_ endpoints: ChatGPTEndpoints, code: String, clientId: String) -> HTTPRequest {
        .form(endpoints.token, [("grant_type", "authorization_code"), ("client_id", clientId), ("code", code),
                                ("code_verifier", verifier), ("redirect_uri", redirect), ("resource", ChatGPT.api)])
    }
}

func base64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func base64urlDecode(_ text: Substring) -> Data? {
    var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    return Data(base64Encoded: s)
}
