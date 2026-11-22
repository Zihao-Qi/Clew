#if DEBUG
import AppKit
import ClewAgent
import ClewAI
import ClewCore
import ClewDomain
import ClewStore
import SwiftUI

/// Recorded answers for the app's AI: models, a streamed reply, or an error.
final class RecordedAI: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, [String])] = []
    private(set) var asked = 0

    func reply(_ status: Int, _ lines: [String]) { lock.withLock { replies.append((status, lines)) } }
    static func steps(_ steps: [String]) -> [String] {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: ["steps": steps]), as: UTF8.self)
        let delta = String(decoding: try! JSONSerialization.data(withJSONObject: ["type": "response.output_text.delta",
                                                                                  "delta": text]), as: UTF8.self)
        return ["data: " + delta, #"data: {"type":"response.completed"}"#]
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path.hasSuffix("/models") {
            return HTTPResponse(status: 200, body: Data("""
            {"models":[{"slug":"gpt-6.2-sol","display_name":"GPT-6.2 Sol","visibility":"list"},
                       {"slug":"gpt-6.1-terra","display_name":"GPT-6.1 Terra","visibility":"list"}]}
            """.utf8))
        }
        if request.url.path.hasSuffix("/revoke") { return HTTPResponse(status: 200) }
        if request.url.path.hasSuffix("/token") {
            return HTTPResponse(status: 400, body: Data(#"{"error":"refresh_token_invalidated"}"#.utf8))
        }
        throw TransportError.other("unexpected")
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let (status, lines) = try lock.withLock { () throws -> (Int, [String]) in
            asked += 1
            guard !replies.isEmpty else { throw TransportError.offline }
            return replies.removeFirst()
        }
        return HTTPStream(status: status, lines: AsyncThrowingStream { c in
            for l in lines { c.yield(l) }
            c.finish()
        })
    }
}

final class MemorySession: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: ChatGPTSession?
    init(_ s: ChatGPTSession?) { session = s }
    func load() throws -> ChatGPTSession? { lock.withLock { session } }
    func save(_ s: ChatGPTSession) throws { lock.withLock { session = s } }
    func clear() throws { lock.withLock { session = nil } }

    static func signedIn(plan: Bool = true) -> MemorySession {
        let e = URL(string: "https://auth.openai.com/x")!
        return MemorySession(ChatGPTSession(
            clientId: "oaiapp_test", endpoints: ChatGPTEndpoints(authorization: e, token: URL(string: "https://auth.openai.com/token")!,
                                                                revocation: URL(string: "https://auth.openai.com/revoke")!, jwks: e),
            access: "test", refresh: "test", idToken: "test", expiresAt: Date().addingTimeInterval(3600),
            scopes: plan ? ChatGPT.scopes.split(separator: " ").map(String.init) : ["openid", "email"],
            account: "user-test", email: "you@example.com"))
    }
}

extension Snapshot {
    static func testAI(_ store: SessionStore, _ transport: RecordedAI, _ name: String) -> AIModel {
        let prefs = UserDefaults(suiteName: "clew-ai-\(name)")!
        prefs.removePersistentDomain(forName: "clew-ai-\(name)")
        let ai = AIModel(prefs: prefs, store: store, transport: transport)
        ai.suggestStepsOn = true
        return ai
    }

    /// `CLEW_AI_CHECK=1` (SPEC "Suggest steps"): the app's AI with recorded answers: what a
    /// task sends, suggestions kept and added as typed, the usage limit, a sign-in OpenAI
    /// ended turning the switch off, and nothing shown when the switch is off.
    static func startAICheck() {
        Task { @MainActor in
            var failures = 0
            func report(_ name: String, _ ok: Bool) {
                if !ok { failures += 1 }
                print(ok ? "PASS" : "FAIL", name); fflush(stdout)
            }
            do {
                let clew = Clew(store: try SQLiteStore.inMemory(), clock: SystemClock(), zones: SystemTimeZone())
                let talk = try clew.addItem(NewItem(title: "Prepare the talk", shape: .today)).id
                try clew.addStep(taskId: talk, title: "Slides")
                let habit = try clew.addItem(NewItem(title: "Run", shape: .habit(.daily))).id
                let model = AppModel(clew: clew, notify: false)
                let transport = RecordedAI()
                let ai = testAI(MemorySession.signedIn(), transport, "check")
                model.useAI(ai)
                await ai.refreshModels()
                report("models listed, the first by default", ai.model == "gpt-6.2-sol")
                report("✨ for a one-off task", model.canSuggestSteps(talk))
                report("no ✨ for a habit", !model.canSuggestSteps(habit))
                let input = model.suggestInput(talk)
                report("sends the title and steps", input?.title == "Prepare the talk" && input?.steps.map(\.name) == ["Slides"])

                transport.reply(200, RecordedAI.steps(["1. Slides", "Write the opening", "Time it"]))
                let ask = SuggestionAsk()
                ask.ask(ai, input!)
                report("thinking", ask.isThinking)
                for _ in 0..<50 where ask.isThinking { try await Task.sleep(for: .milliseconds(20)) }
                report("an existing step is not suggested again", ask.state == .shown(["Write the opening", "Time it"]))
                if model.addStep(to: talk, title: "Write the opening") { ask.take("Write the opening") }
                report("+ adds it at the end and takes it off",
                       model.allSteps(of: talk).map(\.step.title) == ["Slides", "Write the opening"] && ask.state == .shown(["Time it"]))

                transport.reply(200, RecordedAI.steps(["Late"]))
                ask.ask(ai, input!)
                ask.cancel()
                try await Task.sleep(for: .milliseconds(300))
                report("cancelled: nothing appears later", ask.state == .idle)

                transport.reply(429, [#"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#])
                ask.ask(ai, input!)
                for _ in 0..<50 where ask.isThinking { try await Task.sleep(for: .milliseconds(20)) }
                report("usage limit", ask.state == .usageLimit && ai.canSuggestSteps)

                let asked = transport.asked
                transport.reply(200, [#"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_invalid_user"}}}"#])
                ask.ask(ai, input!)
                for _ in 0..<50 where ask.isThinking { try await Task.sleep(for: .milliseconds(20)) }
                report("an ended sign-in: failure shown, switch off, Sign in again",
                       ask.state == .failed && !ai.suggestStepsOn && ai.ended && ai.phase == .signedOut
                       && transport.asked == asked + 1)
                report("no ✨ after it", !model.canSuggestSteps(talk))

                let off = testAI(MemorySession.signedIn(plan: false), RecordedAI(), "noplan")
                model.useAI(off)
                report("no ✨ without the plan permission", !model.canSuggestSteps(talk))
            } catch {
                report("setup: \(error)", false)
            }
            print(failures == 0 ? "ALL PASS" : "\(failures) FAILED"); fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// `CLEW_AI_RENDER=1`: Settings › AI signed out, signed in (with the one-time note),
    /// without the plan permission, and after OpenAI ended the sign-in; Add Step…'s line
    /// with suggestions, thinking, a failure and the usage limit; the details with
    /// suggestions. Light and dark, to the temporary folder's ClewSnapshots.
    static func renderAIAndExit() -> Never {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ClewSnapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            do {
                let clew = Clew(store: try SQLiteStore.inMemory(), clock: SystemClock(), zones: SystemTimeZone())
                try clew.closeCalendarPrompt()
                try clew.setTimelineShown(false)
                let talk = try clew.addItem(NewItem(title: "Prepare the talk", shape: .today)).id
                try clew.addStep(taskId: talk, title: "Make slides")
                let model = AppModel(clew: clew, notify: false)
                let looks: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

                let states: [(String, SessionStore, Bool)] = [
                    ("out", MemorySession(nil), false), ("in", MemorySession.signedIn(), false),
                    ("noplan", MemorySession.signedIn(plan: false), false), ("ended", MemorySession(nil), true),
                ]
                for (name, store, ended) in states {
                    let suite = "clew-ai-render-\(name)"
                    let prefs = UserDefaults(suiteName: suite)!
                    prefs.removePersistentDomain(forName: suite)
                    prefs.set(true, forKey: AIModel.Key.suggestSteps)
                    prefs.set(ended, forKey: AIModel.Key.ended)
                    let ai = AIModel(prefs: prefs, store: store, transport: RecordedAI())
                    await ai.refreshModels()
                    for (look, appearance) in looks {
                        render(AISettings(ai: ai).formStyleGrouped().frame(width: 550), appearance: appearance,
                               to: dir.appendingPathComponent("ai-settings-\(name)-\(look).png"))
                    }
                }
                let ai = testAI(MemorySession.signedIn(), RecordedAI(), "render-line")
                await ai.refreshModels()
                model.useAI(ai)
                let lineStates: [(String, SuggestionAsk.State)] = [
                    ("shown", .shown(["Write the opening line", "List three points that support it",
                                      "Practice out loud once and time yourself"])),
                    ("thinking", .thinking), ("failed", .failed), ("limit", .usageLimit),
                ]
                for (name, state) in lineStates {
                    SuggestionAsk.preset = state
                    for (look, appearance) in looks {
                        render(NewStepLine(model: model, taskId: talk, taskTitle: "Prepare the talk", close: {})
                            .frame(width: 340), appearance: appearance,
                               to: dir.appendingPathComponent("ai-line-\(name)-\(look).png"))
                    }
                }
                SuggestionAsk.preset = lineStates[0].1
                for (look, appearance) in looks {
                    render(RootView(model: model, screen: .detail(talk)), appearance: appearance,
                           to: dir.appendingPathComponent("ai-detail-\(look).png"))
                }
                SuggestionAsk.preset = nil
                exit(0)
            } catch {
                print("render failed:", error)
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(1)
    }
}

private extension View {
    func formStyleGrouped() -> some View { Form { self }.formStyle(.grouped) }
}
#endif
