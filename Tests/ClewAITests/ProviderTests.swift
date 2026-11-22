@testable import ClewAI
import Foundation
import Testing

/// docs/AGENT.md §3: the Responses request, the stream, OpenAI's errors, the models.
@Suite struct ProviderTests {
    let schema = JSONSchema(name: "steps", json: #"{"type":"object"}"#)
    var ask: ModelRequest { ModelRequest(model: "gpt-x", instructions: "Do it.", input: "{}", schema: schema) }

    func provider(_ transport: FakeTransport, store: MemoryStore = MemoryStore(session()),
                  notes: ModelNotes = ModelNotes()) -> ChatGPTProvider {
        ChatGPTProvider(account: ChatGPTAccount(store: store, transport: transport, now: { t0 }), transport: transport,
                        notes: notes)
    }

    @Test func theRequestFollowsOpenAIsRules() throws {
        let r = Responses.request(ask, access: "A1", withSchema: true)
        #expect(r.method == "POST" && r.url.absoluteString == "https://api.openai.com/v1/responses")
        #expect(r.headers["Authorization"] == "Bearer A1")
        let b = body(r)
        #expect(b["store"] as? Bool == false && b["stream"] as? Bool == true)
        #expect(b["instructions"] as? String == "Do it.")
        #expect((b["input"] as? [[String: Any]])?.first?["role"] as? String == "user")
        let format = (b["text"] as? [String: Any])?["format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_schema" && format?["name"] as? String == "steps")
        #expect(format?["strict"] as? Bool == true)
        let refused = ["previous_response_id", "temperature", "max_output_tokens", "metadata", "user", "background",
                       "conversation", "top_p", "truncation", "prompt", "safety_identifier"]
        #expect(Set(b.keys) == ["model", "input", "instructions", "store", "stream", "text"])
        #expect(refused.allSatisfy { b[$0] == nil })
        let plain = body(Responses.request(ask, access: "A1", withSchema: false))
        #expect(plain["text"] == nil)
        #expect((plain["instructions"] as? String)?.hasSuffix(#"JSON schema: {"type":"object"}"#) == true)
    }

    @Test func anAnswerCountsOnlyWhenCompleted() async throws {
        let transport = FakeTransport()
        transport.on("/responses", .lines(200, completed(["[\"a", "\"]"]), headers: ["X-Request-Id": "req_1"]))
        let answer = try await provider(transport).answer(ask)
        #expect(answer == ProviderAnswer(text: "[\"a\"]", requestId: "req_1"))

        transport.on("/responses", .lines(200, Array(completed(["x"]).dropLast())))
        await #expect(throws: ProviderError.incomplete) { try await provider(transport).answer(ask) }
        transport.on("/responses", .lines(200, [#"data: {"type":"response.incomplete"}"#]))
        await #expect(throws: ProviderError.incomplete) { try await provider(transport).answer(ask) }
    }

    @Test func errorsInTheStreamMapToPlainOutcomes() async throws {
        let cases: [(String, ProviderError)] = [
            ("subscription_sharing_usage_limit_exceeded", .usageLimit),
            ("subscription_sharing_usage_unavailable", .unavailable),
            ("subscription_sharing_user_unavailable", .unavailable),
            ("subscription_sharing_user_not_eligible", .notEligible),
            ("subscription_sharing_route_not_supported", .bug("subscription_sharing_route_not_supported")),
            ("chatpass_v2_scope_not_authorized", .bug("chatpass_v2_scope_not_authorized")),
            ("server_error", .failed("server_error")),
        ]
        for (code, expected) in cases {
            let transport = FakeTransport()
            transport.on("/responses", .lines(200, [
                #"data: {"type":"response.failed","response":{"error":{"code":"\#(code)","message":"m"}}}"#]))
            await #expect(throws: expected, "\(code)") { try await provider(transport).answer(ask) }
        }
    }

    @Test func errorsBeforeTheStreamMapByCodeThenStatus() async throws {
        let cases: [(Int, String, ProviderError)] = [
            (429, #"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#, .usageLimit),
            (403, #"{"error":{"code":"subscription_sharing_user_not_eligible"}}"#, .notEligible),
            (503, #"{"detail":"subscription_sharing_usage_limit_exceeded"}"#, .unavailable),   // detail is not a code
            (403, #"{"detail":"region"}"#, .failed("http_403")),
            (429, "", .usageLimit),
        ]
        for (status, text, expected) in cases {
            let transport = FakeTransport()
            transport.onJSON("/responses", status, text)
            await #expect(throws: expected, "\(status) \(text)") { try await provider(transport).answer(ask) }
        }
    }

    @Test func aModelRefusingStructuredOutputIsAskedOnceWithoutItAndRemembered() async throws {
        let transport = FakeTransport()
        let refusal = #"{"error":{"code":"subscription_sharing_unsupported_capability","param":"text.format"}}"#
        transport.onJSON("/responses", 400, refusal)
        transport.on("/responses", .lines(200, completed(["ok"])))
        let saved = Saved()
        let notes = ModelNotes(onChange: { saved.set($0) })
        #expect(try await provider(transport, notes: notes).answer(ask).text == "ok")
        let sent = transport.sent("/responses")
        #expect(sent.count == 2 && body(sent[0])["text"] != nil && body(sent[1])["text"] == nil)
        #expect(saved.value == ["gpt-x"])

        // Next time it is asked without it at once.
        transport.on("/responses", .lines(200, completed(["ok"])))
        _ = try await provider(transport, notes: notes).answer(ask)
        #expect(transport.sent("/responses").count == 3 && body(transport.sent("/responses")[2])["text"] == nil)

        // A second refusal is a failure, not a loop; another capability is never retried.
        let again = FakeTransport()
        again.onJSON("/responses", 400, refusal)
        again.onJSON("/responses", 400, refusal)
        await #expect(throws: ProviderError.unsupported("text.format")) { try await provider(again).answer(ask) }
        #expect(again.sent("/responses").count == 2)
        let other = FakeTransport()
        other.onJSON("/responses", 400, #"{"error":{"code":"subscription_sharing_unsupported_capability","param":"model"}}"#)
        await #expect(throws: ProviderError.unsupported("model")) { try await provider(other).answer(ask) }
        #expect(other.sent("/responses").count == 1)
    }

    @Test func anInvalidUserEndsTheSignInOnlyIfARefreshConfirmsIt() async throws {
        let invalid = #"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_invalid_user"}}}"#
        let confirmed = FakeTransport()
        confirmed.on("/responses", .lines(200, [invalid]))
        confirmed.onJSON("/token", 400, #"{"error":"refresh_token_invalidated"}"#)
        let store = MemoryStore(session())
        await #expect(throws: ProviderError.signInEnded) { try await provider(confirmed, store: store).answer(ask) }
        #expect(try store.load() == nil)

        let fine = FakeTransport()
        fine.onJSON("/responses", 401, #"{"detail":"no"}"#)
        fine.onJSON("/token", 200, #"{"access_token":"A2","refresh_token":"R2"}"#)
        let kept = MemoryStore(session())
        await #expect(throws: ProviderError.unavailable) { try await provider(fine, store: kept).answer(ask) }
        #expect(try kept.load()?.access == "A2")
        #expect(fine.sent("/responses").count == 1)   // never asked again by itself
    }

    @Test func aRefusalAfterTextIsNotRetried() async throws {
        let transport = FakeTransport()
        transport.on("/responses", .lines(200, [
            #"data: {"type":"response.output_text.delta","delta":"{"}"#,
            #"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_unsupported_capability","param":"text.format"}}}"#]))
        transport.on("/responses", .lines(200, completed(["ok"])))
        await #expect(throws: ProviderError.unsupported(nil)) { try await provider(transport).answer(ask) }
        #expect(transport.sent("/responses").count == 1)
    }

    @Test func theModelsListConfirmsAnInvalidUserByARefresh() async throws {
        let ended = FakeTransport()
        ended.onJSON("/models", 401, #"{"detail":"no"}"#)
        ended.onJSON("/token", 400, #"{"error":"refresh_token_expired"}"#)
        let store = MemoryStore(session())
        let account = ChatGPTAccount(store: store, transport: ended, now: { t0 })
        await #expect(throws: ProviderError.signInEnded) { try await ChatGPTModels.list(account, ended) }
        #expect(try store.load() == nil)

        let fine = FakeTransport()
        fine.onJSON("/models", 200, #"{"models":[{"slug":"a","visibility":"list"}]}"#)
        let ok = ChatGPTAccount(store: MemoryStore(session()), transport: fine, now: { t0 })
        #expect(try await ChatGPTModels.list(ok, fine).map(\.slug) == ["a"])
        #expect(fine.sent("/models").first?.headers["Authorization"] == "Bearer A1")
    }

    @Test func networkFailuresMapToOfflineAndTimedOut() async throws {
        let transport = FakeTransport()
        transport.on("/responses", .fail(TransportError.offline))
        transport.on("/responses", .fail(TransportError.timedOut))
        await #expect(throws: ProviderError.offline) { try await provider(transport).answer(ask) }
        await #expect(throws: ProviderError.timedOut) { try await provider(transport).answer(ask) }
    }

    @Test func modelsAreTheListedOnesInOrder() throws {
        let r = ChatGPTModels.request(access: "A1")
        #expect(r.url.absoluteString == "https://api.openai.com/v1/models" && r.headers["Authorization"] == "Bearer A1")
        let models = try ChatGPTModels.parse(HTTPResponse(status: 200, body: Data("""
        {"models":[{"slug":"b","display_name":"B","visibility":"list"},{"slug":"h","visibility":"hide"},
                   {"slug":"a","display_name":"A","visibility":"list"},{"slug":"c","visibility":"list"}]}
        """.utf8)))
        #expect(models == [ChatGPTModel(slug: "b", displayName: "B"), ChatGPTModel(slug: "a", displayName: "A"),
                           ChatGPTModel(slug: "c", displayName: "c")])
        #expect(throws: ProviderError.usageLimit) { try ChatGPTModels.parse(HTTPResponse(status: 429)) }
    }

    @Test func eventLinesOtherThanClewsAreIgnored() {
        #expect(Responses.event("event: response.output_text.delta") == nil)
        #expect(Responses.event("data: [DONE]") == nil)
        #expect(Responses.event(#"data: {"type":"response.created"}"#) == nil)
        #expect(Responses.event(#"data:{"type":"response.output_text.delta","delta":"x"}"#) == .text("x"))
    }
}

final class Saved: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Set<String> = []
    var value: Set<String> { lock.withLock { stored } }
    func set(_ v: Set<String>) { lock.withLock { stored = v } }
}
