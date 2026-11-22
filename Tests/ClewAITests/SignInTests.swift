import ClewAI
import Foundation
import Testing

/// docs/AGENT.md §3: the sign-in's address, callback, exchange and discovery.
@Suite struct SignInTests {
    let attempt = SignInAttempt(port: 1455, random: { n in String(repeating: n == 32 ? "v" : "s", count: n) },
                                sha256: { Data($0.reversed()) })

    func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
    }

    @Test func firstSignInRegistersAsClewWithPKCE() {
        let q = query(attempt.authorizeURL(endpoints, clientId: nil, hostId: "urn:uuid:h", idTokenHint: "old"))
        #expect(q["client_id"] == "dynamic_agent_client")
        #expect(q["agent_name_hint"] == "Clew")
        #expect(q["id_token_hint"] == nil)   // a hint only goes with an issued id
        #expect(q["ext_agent_host_id"] == "urn:uuid:h")
        #expect(q["redirect_uri"] == "http://127.0.0.1:1455/auth/callback")
        #expect(q["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        #expect(q["resource"] == "https://api.openai.com/v1")
        #expect(q["code_challenge_method"] == "S256")
        // The challenge is base64url(sha256(verifier)), here a reversed verifier.
        let expected = Data(String(repeating: "v", count: 32).utf8.reversed()).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        #expect(q["code_challenge"] == expected)
        #expect(q["state"] == attempt.state && q["nonce"] == attempt.nonce)
        #expect(q["prompt"] == nil)
    }

    @Test func laterSignInUsesTheIssuedIdAndHintAndConsentAsksAgain() {
        let q = query(attempt.authorizeURL(endpoints, clientId: "oaiapp_1", hostId: "h", idTokenHint: "old", consent: true))
        #expect(q["client_id"] == "oaiapp_1")
        #expect(q["agent_name_hint"] == nil)
        #expect(q["id_token_hint"] == "old")
        #expect(q["prompt"] == "consent")
    }

    @Test func callbackChecksStateFirstThenRefusalThenCode() {
        #expect(throws: SignInError.stateMismatch) {
            try attempt.callback(["state": "x", "error": "access_denied"], keptClientId: nil)
        }
        #expect(throws: SignInError.denied) {
            try attempt.callback(["state": attempt.state, "error": "access_denied", "code": "c"], keptClientId: nil)
        }
        #expect(throws: SignInError.noCode) { try attempt.callback(["state": attempt.state], keptClientId: nil) }
        #expect(throws: SignInError.noClientId) {
            try attempt.callback(["state": attempt.state, "code": "c"], keptClientId: nil)
        }
        #expect(throws: SignInError.noClientId) {
            try attempt.callback(["state": attempt.state, "code": "c", "client_id": "dynamic_agent_client"], keptClientId: nil)
        }
        #expect(throws: SignInError.clientIdChanged) {
            try attempt.callback(["state": attempt.state, "code": "c", "client_id": "oaiapp_2"], keptClientId: "oaiapp_1")
        }
        let first = try? attempt.callback(["state": attempt.state, "code": "c", "client_id": "oaiapp_9"], keptClientId: nil)
        #expect(first?.clientId == "oaiapp_9" && first?.code == "c")
        let later = try? attempt.callback(["state": attempt.state, "code": "c"], keptClientId: "oaiapp_1")
        #expect(later?.clientId == "oaiapp_1")
    }

    @Test func exchangeSendsTheVerifierAndTheSameRedirect() {
        let r = attempt.exchange(endpoints, code: "c+/=", clientId: "oaiapp_1")
        #expect(r.method == "POST" && r.url == endpoints.token)
        #expect(r.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(r.formFields == ["grant_type": "authorization_code", "client_id": "oaiapp_1", "code": "c+/=",
                                 "code_verifier": attempt.verifier, "redirect_uri": attempt.redirect,
                                 "resource": "https://api.openai.com/v1"])
        #expect(String(decoding: r.body!, as: UTF8.self).contains("code=c%2B%2F%3D"))
    }

    @Test func discoveryRefusesAnotherIssuerOrHost() throws {
        func config(issuer: String = "https://auth.openai.com", host: String = "auth.openai.com") -> HTTPResponse {
            HTTPResponse(status: 200, body: Data("""
            {"issuer":"\(issuer)","authorization_endpoint":"https://\(host)/a","token_endpoint":"https://auth.openai.com/t",
             "revocation_endpoint":"https://auth.openai.com/r","jwks_uri":"https://auth.openai.com/j"}
            """.utf8))
        }
        #expect(try ChatGPTEndpoints.parse(config()).revocation.path == "/r")
        #expect(throws: SignInError.discovery) { try ChatGPTEndpoints.parse(config(issuer: "https://evil.example")) }
        #expect(throws: SignInError.discovery) { try ChatGPTEndpoints.parse(config(host: "evil.example")) }
    }
}
