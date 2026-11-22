import Foundation

/// Where the session is kept: the Keychain in the app, memory in tests.
public protocol SessionStore: Sendable {
    func load() throws -> ChatGPTSession?
    func save(_ session: ChatGPTSession) throws
    func clear() throws
}

/// The signed-in account: hands out a valid access token, refreshing it when it is about to
/// expire. Refreshes are serialized, since each one rotates the refresh token (docs/AGENT.md §3).
public actor ChatGPTAccount {
    let store: SessionStore
    let transport: HTTPTransport
    let now: @Sendable () -> Date
    private var refreshing: Task<ChatGPTSession, Error>?

    /// An access token this close to expiry is refreshed first.
    static let margin: TimeInterval = 60

    public init(store: SessionStore, transport: HTTPTransport, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.transport = transport
        self.now = now
    }

    public func session() throws -> ChatGPTSession {
        guard let session = try store.load() else { throw ProviderError.notSignedIn }
        return session
    }

    /// A valid access token for a request that needs the plan.
    public func access() async throws -> String {
        let current = try session()
        guard current.hasPlanPermission else { throw ProviderError.noPlanPermission }
        if current.expiresAt.timeIntervalSince(now()) > Self.margin { return current.access }
        let next = try await refresh(from: current)
        // A refresh may narrow the grant (review).
        guard next.hasPlanPermission else { throw ProviderError.noPlanPermission }
        return next.access
    }

    /// Refreshes now, whatever the expiry: to confirm whether OpenAI ended the sign-in
    /// (`subscription_sharing_invalid_user`, a 401). Throws `signInEnded` if it did.
    public func confirm() async throws {
        _ = try await refresh(from: try session())
    }

    private func refresh(from current: ChatGPTSession) async throws -> ChatGPTSession {
        if let refreshing { return try await refreshing.value }
        let task = Task { () throws -> ChatGPTSession in
            let response: HTTPResponse
            do { response = try await transport.send(Tokens.refreshRequest(current)) } catch {
                throw ProviderError.from(transport: error)
            }
            do {
                let next = Tokens.refreshed(current, try Tokens.parse(response), now: now())
                try store.save(next)
                return next
            } catch let error as TokenError {
                if error.endsSignIn {
                    try? store.clear()
                    throw ProviderError.signInEnded
                }
                if error.code == "invalid_client" { throw ProviderError.bug("invalid_client") }
                throw error.status >= 500 ? ProviderError.unavailable : ProviderError.failed(error.code)
            }
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }
}

extension ProviderError {
    static func from(transport error: Error) -> Error {
        if error is CancellationError { return error }
        if let error = error as? ProviderError { return error }
        switch error as? TransportError {
        case .offline: return ProviderError.offline
        case .timedOut: return ProviderError.timedOut
        case .other(let what): return ProviderError.failed(what)
        case nil: return ProviderError.failed("transport")
        }
    }
}
