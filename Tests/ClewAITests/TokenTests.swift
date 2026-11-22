@testable import ClewAI
import Foundation
import Testing

/// docs/AGENT.md §3: tokens, refresh (rotating, serialized), revocation, the ID token.
@Suite struct TokenTests {
    @Test func tokenErrorsKeepOnlyTheCode() {
        let flat = HTTPResponse(status: 400, body: Data(#"{"error":"invalid_grant","error_description":"secret"}"#.utf8))
        #expect(throws: TokenError(code: "invalid_grant", status: 400)) { try Tokens.parse(flat) }
        let nested = HTTPResponse(status: 401, body: Data(#"{"error":{"code":"refresh_token_reused"}}"#.utf8))
        #expect(throws: TokenError(code: "refresh_token_reused", status: 401)) { try Tokens.parse(nested) }
        #expect(throws: TokenError(code: "http_502", status: 502)) { try Tokens.parse(HTTPResponse(status: 502)) }
    }

    @Test func endingCodesAreExactlyOpenAIsList() {
        for code in ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                     "refresh_token_invalidated", "refresh_token_reused"] {
            #expect(TokenError(code: code, status: 400).endsSignIn, "\(code)")
        }
        #expect(!TokenError(code: "invalid_client", status: 400).endsSignIn)
        #expect(!TokenError(code: "http_503", status: 503).endsSignIn)
    }

    @Test func refreshSendsNoScopeAndReplacesEverythingTogether() throws {
        let r = Tokens.refreshRequest(session())
        #expect(r.formFields == ["grant_type": "refresh_token", "client_id": "oaiapp_1", "refresh_token": "R1",
                                 "resource": "https://api.openai.com/v1"])
        let answer = try Tokens.parse(HTTPResponse(status: 200, body: Data(
            #"{"access_token":"A2","refresh_token":"R2","expires_in":1800,"scope":"openid email"}"#.utf8)))
        let next = Tokens.refreshed(session(), answer, now: t0)
        #expect(next.access == "A2" && next.refresh == "R2" && next.idToken == "I1")
        #expect(next.expiresAt == t0.addingTimeInterval(1800))
        #expect(next.scopes == ["openid", "email"] && !next.hasPlanPermission)
        let newId = Tokens.refreshed(session(), TokenAnswer(access: "A2", refresh: "R2", idToken: "I2", expiresIn: 60,
                                                            scopes: nil), now: t0)
        #expect(newId.idToken == "I2")
        let noRotation = Tokens.refreshed(session(), TokenAnswer(access: "A3", refresh: nil, idToken: nil,
                                                                 expiresIn: 60, scopes: nil), now: t0)
        #expect(noRotation.refresh == "R1" && noRotation.scopes == session().scopes)
    }

    @Test func revokeSendsTheRefreshToken() {
        let r = Tokens.revokeRequest(session())
        #expect(r.url == endpoints.revocation)
        #expect(r.formFields == ["token": "R1", "token_type_hint": "refresh_token", "client_id": "oaiapp_1"])
    }

    @Test func aFreshTokenIsUsedWithoutARefresh() async throws {
        let transport = FakeTransport()
        let account = ChatGPTAccount(store: MemoryStore(session(expiresIn: 61)), transport: transport, now: { t0 })
        #expect(try await account.access() == "A1")
        #expect(transport.requests.isEmpty)
    }

    @Test func anExpiringTokenIsRefreshedOnceForTwoCallers() async throws {
        let transport = FakeTransport()
        transport.delay = .milliseconds(50)
        transport.onJSON("/token", 200, #"{"access_token":"A2","refresh_token":"R2","expires_in":3600}"#)
        let store = MemoryStore(session(expiresIn: 59))
        let account = ChatGPTAccount(store: store, transport: transport, now: { t0 })
        async let one = account.access()
        async let two = account.access()
        #expect(try await [one, two] == ["A2", "A2"])
        #expect(transport.sent("/token").count == 1)
        #expect(try store.load()?.refresh == "R2" && store.saves == 1)
    }

    @Test func anEndingRefreshClearsTheSignIn() async throws {
        let transport = FakeTransport()
        transport.onJSON("/token", 400, #"{"error":"refresh_token_expired"}"#)
        let store = MemoryStore(session(expiresIn: 0))
        let account = ChatGPTAccount(store: store, transport: transport, now: { t0 })
        await #expect(throws: ProviderError.signInEnded) { try await account.access() }
        #expect(try store.load() == nil)
    }

    @Test func otherRefreshFailuresKeepTheSignIn() async throws {
        let transport = FakeTransport()
        transport.onJSON("/token", 400, #"{"error":"invalid_client"}"#)
        transport.onJSON("/token", 503, "{}")
        transport.on("/token", .fail(TransportError.offline))
        let store = MemoryStore(session(expiresIn: 0))
        let account = ChatGPTAccount(store: store, transport: transport, now: { t0 })
        await #expect(throws: ProviderError.bug("invalid_client")) { try await account.access() }
        await #expect(throws: ProviderError.unavailable) { try await account.access() }
        await #expect(throws: ProviderError.offline) { try await account.access() }
        #expect(try store.load() != nil)
    }

    @Test func aRefreshThatDropsThePlanPermissionStops() async throws {
        let transport = FakeTransport()
        transport.onJSON("/token", 200, #"{"access_token":"A2","refresh_token":"R2","scope":"openid email"}"#)
        let account = ChatGPTAccount(store: MemoryStore(session(expiresIn: 0)), transport: transport, now: { t0 })
        await #expect(throws: ProviderError.noPlanPermission) { try await account.access() }

        // Confirming an invalid user by a refresh says so too (review, AI-M).
        let again = FakeTransport()
        again.onJSON("/token", 200, #"{"access_token":"A2","refresh_token":"R2","scope":"openid email"}"#)
        let confirming = ChatGPTAccount(store: MemoryStore(session()), transport: again, now: { t0 })
        await #expect(throws: ProviderError.noPlanPermission) { try await confirming.confirm() }
    }

    @Test func withoutPlanPermissionNothingIsAsked() async throws {
        let transport = FakeTransport()
        let account = ChatGPTAccount(store: MemoryStore(session(scopes: ["openid", "email"])), transport: transport,
                                     now: { t0 })
        await #expect(throws: ProviderError.noPlanPermission) { try await account.access() }
        let nobody = ChatGPTAccount(store: MemoryStore(), transport: transport, now: { t0 })
        await #expect(throws: ProviderError.notSignedIn) { try await nobody.access() }
        #expect(transport.requests.isEmpty)
    }

    // MARK: ID token

    func jwt(header: [String: Any] = ["alg": "RS256", "kid": "k1"], _ claims: [String: Any]) -> String {
        func part(_ o: [String: Any]) -> String {
            base64url(try! JSONSerialization.data(withJSONObject: o))
        }
        return part(header) + "." + part(claims) + "." + base64url(Data([1, 2, 3]))
    }
    var good: [String: Any] {
        ["iss": "https://auth.openai.com", "aud": "oaiapp_1", "exp": t0.timeIntervalSince1970 + 60, "nonce": "n",
         "sub": "user-1", "email": "a@b.c"]
    }

    @Test func idTokenClaimsAreEachChecked() throws {
        let text = jwt(good)
        let token = try IDToken(text)
        try token.checkClaims(clientId: "oaiapp_1", nonce: "n", now: t0)
        #expect(token.subject == "user-1" && token.email == "a@b.c" && token.keyId == "k1")
        #expect(token.signature == Data([1, 2, 3]))
        #expect(token.signingInput == Data(text.split(separator: ".").prefix(2).joined(separator: ".").utf8))
        func refused(_ change: (inout [String: Any]) -> Void, header: [String: Any] = ["alg": "RS256"],
                     nonce: String? = "n") -> SignInError? {
            var claims = good
            change(&claims)
            do { try IDToken(jwt(header: header, claims)).checkClaims(clientId: "oaiapp_1", nonce: nonce, now: t0) } catch {
                return error as? SignInError
            }
            return nil
        }
        #expect(refused({ _ in }, header: ["alg": "none"]) == .idToken("alg"))
        #expect(refused({ $0["iss"] = "https://evil.example" }) == .idToken("iss"))
        #expect(refused({ $0["aud"] = "oaiapp_2" }) == .idToken("aud"))
        #expect(refused({ $0["aud"] = ["x", "oaiapp_1"] }) == nil)
        #expect(refused({ $0["exp"] = t0.timeIntervalSince1970 }) == .idToken("exp"))
        #expect(refused({ $0["nonce"] = "m" }) == .idToken("nonce"))
        #expect(refused({ $0["nonce"] = "m" }, nonce: nil) == nil)   // a refreshed token has no nonce to match
        #expect(refused({ $0["sub"] = nil }) == .idToken("sub"))
        #expect(throws: SignInError.idToken("malformed")) { try IDToken("a.b") }
    }

    @Test func signingKeysBecomeDER() throws {
        let response = HTTPResponse(status: 200, body: Data("""
        {"keys":[{"kty":"RSA","kid":"k1","use":"sig","n":"\(base64url(Data([0x80, 0x01])))","e":"AQAB"},
                 {"kty":"EC","kid":"k2"},{"kty":"RSA","kid":"k3","use":"enc","n":"AQ","e":"AQ"}]}
        """.utf8))
        let keys = try SigningKey.parse(response)
        #expect(keys.map(\.keyId) == ["k1"])
        // SEQUENCE { INTEGER 0x00 0x80 0x01 (a leading zero for the high bit), INTEGER 0x01 0x00 0x01 }
        #expect(keys[0].der == Data([0x30, 0x0a, 0x02, 0x03, 0x00, 0x80, 0x01, 0x02, 0x03, 0x01, 0x00, 0x01]))
        let long = SigningKey(keyId: "x", modulus: Data(repeating: 0x7f, count: 200), exponent: Data([3]))
        #expect(Array(long.der.prefix(7)) == [0x30, 0x81, 0xce, 0x02, 0x81, 0xc8, 0x7f])
    }
}
