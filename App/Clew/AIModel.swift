import AppKit
import ClewAgent
import ClewAI
import ClewDomain
import Foundation
import Observation
import os

/// Clew's AI (docs/AGENT.md; SPEC "Suggest steps"): the ChatGPT sign-in and the jobs.
/// Off until the person signs in. Non-secret settings live in this Mac's preferences, not
/// in Clew's data, so they are never exported or backed up; the tokens are in the Keychain.
@MainActor @Observable
final class AIModel {
    enum Phase: Equatable {
        case signedOut
        case signingIn
        case signedIn
    }

    private(set) var phase: Phase = .signedOut
    private(set) var email: String?
    private(set) var hasPlanPermission = false
    private(set) var models: [ChatGPTModel] = []
    /// A sign-in problem to show in Settings › AI, or nil.
    private(set) var message: String?
    /// OpenAI ended the sign-in: "Sign in again".
    private(set) var ended = false
    /// The last sign-out could not confirm the token was revoked.
    private(set) var revocationUnconfirmed = false

    var model: String? {
        get { access(keyPath: \.model); return prefs.string(forKey: Key.model).flatMap { m in models.isEmpty || models.contains { $0.slug == m } ? m : nil } ?? models.first?.slug }
        set { withMutation(keyPath: \.model) { prefs.set(newValue, forKey: Key.model) } }
    }
    var suggestStepsOn: Bool {
        get { access(keyPath: \.suggestStepsOn); return prefs.bool(forKey: Key.suggestSteps) }
        set { withMutation(keyPath: \.suggestStepsOn) { prefs.set(newValue, forKey: Key.suggestSteps) } }
    }
    var notEligible: Bool {
        get { access(keyPath: \.notEligible); return prefs.bool(forKey: Key.notEligible) }
        set { withMutation(keyPath: \.notEligible) { prefs.set(newValue, forKey: Key.notEligible) } }
    }
    /// OpenAI's rule: the first time, "You're using your ChatGPT plan" until Got it.
    var planNoteSeen: Bool {
        get { access(keyPath: \.planNoteSeen); return prefs.bool(forKey: Key.gotIt) }
        set { withMutation(keyPath: \.planNoteSeen) { prefs.set(newValue, forKey: Key.gotIt) } }
    }

    /// Suggest steps can be asked: signed in with the plan's permission, the switch on.
    var canSuggestSteps: Bool {
        phase == .signedIn && hasPlanPermission && !notEligible && suggestStepsOn && model != nil
    }

    enum Key {
        static let clientId = "ai.clientId", hostId = "ai.hostId", model = "ai.model"
        static let suggestSteps = "ai.suggestSteps", gotIt = "ai.planNoteSeen", notEligible = "ai.notEligible"
        static let noSchema = "ai.noSchemaModels", ended = "ai.ended"
    }

    @ObservationIgnored let prefs: UserDefaults
    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let transport: HTTPTransport
    @ObservationIgnored private let account: ChatGPTAccount
    @ObservationIgnored private let provider: ChatGPTProvider
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var callback: LoopbackCallback?
    @ObservationIgnored private let log = Logger(subsystem: "io.github.zihao-qi.clew", category: "ai")

    init(prefs: UserDefaults = .standard, store: SessionStore = KeychainSession(),
         transport: HTTPTransport = URLSessionTransport()) {
        self.prefs = prefs
        self.store = store
        self.transport = transport
        account = ChatGPTAccount(store: store, transport: transport, now: { Date() })
        let noSchema = Set(prefs.stringArray(forKey: Key.noSchema) ?? [])
        provider = ChatGPTProvider(account: account, transport: transport, notes: ModelNotes(noSchema: noSchema) { set in
            // UserDefaults is thread-safe; read again by its name, not captured.
            UserDefaults.standard.set(Array(set).sorted(), forKey: Key.noSchema)
        })
        ended = prefs.bool(forKey: Key.ended)
        readSession()
    }

    private func readSession() {
        let session = try? store.load()
        phase = session == nil ? (phase == .signingIn ? .signingIn : .signedOut) : .signedIn
        email = session?.email
        hasPlanPermission = session?.hasPlanPermission ?? false
    }

    // MARK: Sign in

    /// Continue with ChatGPT: the browser, then back here. `consent` asks again for the
    /// plan permission the person declined.
    func signIn(consent: Bool = false) {
        guard phase != .signingIn else { return }
        message = nil
        let before = phase
        phase = .signingIn
        signInTask = Task {
            do {
                try await runSignIn(consent: consent)
            } catch is CancellationError {
            } catch {
                message = Self.text(for: error)
                logOutcome("signIn", error)
            }
            callback?.stop()
            callback = nil
            if phase == .signingIn { phase = before == .signedIn && (try? store.load()) != nil ? .signedIn : .signedOut }
            readSession()
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        callback?.stop()
    }

    private func runSignIn(consent: Bool) async throws {
        let endpoints = try ChatGPTEndpoints.parse(try await transport.send(ChatGPTEndpoints.discoveryRequest))
        let hostId = prefs.string(forKey: Key.hostId) ?? "urn:uuid:\(UUID().uuidString.lowercased())"
        prefs.set(hostId, forKey: Key.hostId)
        let keptClient = prefs.string(forKey: Key.clientId)
        let previous = try? store.load()

        let listener = LoopbackCallback()
        callback = listener
        try await listener.bind()
        let attempt = SignInAttempt(port: listener.port, random: AICrypto.random, sha256: AICrypto.sha256)
        let url = attempt.authorizeURL(endpoints, clientId: keptClient, hostId: hostId,
                                       idTokenHint: keptClient == nil ? nil : previous?.idToken, consent: consent)
        NSWorkspace.shared.open(url)
        let query = try await withTaskCancellationHandler {
            try await listener.wait()
        } onCancel: {
            Task { @MainActor in listener.stop() }
        }
        NSApp.activate()
        let (code, clientId) = try attempt.callback(query, keptClientId: keptClient)
        prefs.set(clientId, forKey: Key.clientId)

        let answer: TokenAnswer
        do { answer = try Tokens.parse(try await transport.send(attempt.exchange(endpoints, code: code, clientId: clientId))) } catch let e as TokenError {
            throw e.code == "invalid_grant" ? SignInError.invalidGrant : SignInError.exchange(e.code)
        }
        guard let idText = answer.idToken, let refresh = answer.refresh else { throw SignInError.exchange("fields") }
        let id = try IDToken(idText)
        try id.checkClaims(clientId: clientId, nonce: attempt.nonce, now: Date())
        let keys = try SigningKey.parse(try await transport.send(HTTPRequest(url: endpoints.jwks)))
        guard AICrypto.verify(id, keys: keys) else { throw SignInError.idToken("signature") }

        // Another account: the old one is signed out first.
        if let previous, previous.account != id.subject {
            _ = await revoke(previous)
        }
        let session = ChatGPTSession(clientId: clientId, endpoints: endpoints, access: answer.access, refresh: refresh,
                                     idToken: idText, expiresAt: Date().addingTimeInterval(answer.expiresIn),
                                     scopes: answer.scopes ?? [], account: id.subject ?? "", email: id.email)
        try store.save(session)
        let first = previous == nil
        if first || previous?.account != id.subject {
            suggestStepsOn = true   // signing in turns Suggest steps on
            notEligible = false
        }
        ended = false
        prefs.set(false, forKey: Key.ended)
        revocationUnconfirmed = false
        phase = .signedIn
        readSession()
        await refreshModels()
    }

    /// The plan's models, read after signing in and when Settings › AI opens.
    func refreshModels() async {
        guard phase == .signedIn, hasPlanPermission else { return }
        do {
            models = try await ChatGPTModels.list(account, transport)
        } catch {
            handle(error as? ProviderError)
        }
    }

    // MARK: Sign out

    /// Revokes the refresh token (a few tries on network errors or 5xx), then clears the
    /// tokens either way. The issued client id and this Mac's host id stay.
    func signOut() {
        Task {
            let session = try? store.load()
            var confirmed = true
            if let session { confirmed = await revoke(session) }
            try? store.clear()
            revocationUnconfirmed = !confirmed
            models = []
            message = nil
            readSession()
        }
    }

    private func revoke(_ session: ChatGPTSession) async -> Bool {
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(attempt)) }
            guard let response = try? await transport.send(Tokens.revokeRequest(session)) else { continue }
            if response.status == 200 { return true }
            if response.status < 500 { return false }
        }
        return false
    }

    // MARK: Jobs

    /// Suggest steps for a task (SPEC "Suggest steps"). Nothing is kept.
    func suggestSteps(_ input: SuggestSteps.Input) async -> Result<[String], JobFailure> {
        guard canSuggestSteps, let model else { return .failure(JobFailure(provider: .notSignedIn)) }
        let log = self.log
        let result = await Agent.run(SuggestSteps(), input: input, model: model, provider: provider) { record in
            #if DEBUG
            log.debug("job=\(record.job, privacy: .public) model=\(record.model, privacy: .public) bytes=\(record.inputBytes) seconds=\(record.seconds, format: .fixed(precision: 1)) outcome=\(record.outcome, privacy: .public) request=\(record.requestId ?? "-", privacy: .public)")
            #endif
        }
        if case .failure(let failure) = result { handle(failure.provider) }
        return result
    }

    /// A failure that changes the sign-in's state.
    private func handle(_ error: ProviderError?) {
        switch error {
        case .signInEnded?:
            ended = true
            prefs.set(true, forKey: Key.ended)
            suggestStepsOn = false
            readSession()
        case .notEligible?:
            notEligible = true
        case .noPlanPermission?, .notSignedIn?:
            readSession()
        default: break
        }
    }

    private func logOutcome(_ what: String, _ error: Error) {
        #if DEBUG
        log.debug("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        #endif
    }

    static func text(for error: Error) -> String {
        switch error {
        case SignInError.denied: String(localized: "Sign-in was cancelled in the browser.")
        case is LoopbackCallback.Failure: String(localized: "Clew couldn't wait for the browser. Try again.")
        case ProviderError.offline, TransportError.offline: String(localized: "You're offline. Try again when connected.")
        default: String(localized: "Couldn't sign in. Try again.")
        }
    }
}
