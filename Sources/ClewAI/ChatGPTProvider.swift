import Foundation

/// Models that refused structured output, kept so they are asked without it next time
/// (docs/AGENT.md §3). The app saves them in this Mac's preferences.
public actor ModelNotes {
    private var noSchema: Set<String>
    private let onChange: @Sendable (Set<String>) -> Void

    public init(noSchema: Set<String> = [], onChange: @escaping @Sendable (Set<String>) -> Void = { _ in }) {
        self.noSchema = noSchema
        self.onChange = onChange
    }

    public func needsNoSchema(_ model: String) -> Bool { noSchema.contains(model) }

    func markNoSchema(_ model: String) {
        guard noSchema.insert(model).inserted else { return }
        onChange(noSchema)
    }
}

/// The person's ChatGPT plan through `POST /v1/responses` (docs/AGENT.md §3).
public struct ChatGPTProvider: Provider {
    let account: ChatGPTAccount
    let transport: HTTPTransport
    let notes: ModelNotes

    public init(account: ChatGPTAccount, transport: HTTPTransport, notes: ModelNotes = ModelNotes()) {
        self.account = account
        self.transport = transport
        self.notes = notes
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: ModelRequest, _ out: AsyncThrowingStream<ProviderEvent, Error>.Continuation) async throws {
        let refused = await notes.needsNoSchema(request.model)
        let withSchema = request.schema != nil && !refused
        do {
            try await ask(request, withSchema: withSchema, out)
        } catch Refusal.schema where withSchema {
            // The model refused structured output: ask once more without it, and remember.
            await notes.markNoSchema(request.model)
            do { try await ask(request, withSchema: false, out) } catch Refusal.schema {
                throw ProviderError.unsupported("text.format")
            }
        } catch Refusal.schema {
            throw ProviderError.unsupported("text.format")
        }
    }

    private enum Refusal: Error { case schema }

    private func ask(_ request: ModelRequest, withSchema: Bool,
                     _ out: AsyncThrowingStream<ProviderEvent, Error>.Continuation) async throws {
        let access = try await account.access()
        let stream: HTTPStream
        do { stream = try await transport.stream(Responses.request(request, access: access, withSchema: withSchema)) } catch {
            throw ProviderError.from(transport: error)
        }
        do {
            if stream.status != 200 {
                var body = ""
                for try await line in stream.lines { body += line }
                try await fail(Responses.failure(status: stream.status, body: Data(body.utf8)))
            }
            out.yield(.started(requestId: stream.requestId))
            var sentText = false
            for try await line in stream.lines {
                try Task.checkCancellation()
                switch Responses.event(line) {
                case .text(let delta)?:
                    sentText = true
                    out.yield(.text(delta))
                case .completed?:
                    out.yield(.done)
                    return
                case .failed(let failure)?:
                    if case .unsupported = failure, sentText { throw ProviderError.unsupported(nil) }
                    try await fail(failure)
                case .incomplete?:
                    throw ProviderError.incomplete
                case nil:
                    continue
                }
            }
            try Task.checkCancellation()
            throw ProviderError.incomplete   // the stream just ended
        } catch let error where !(error is ProviderError) && !(error is CancellationError) && !(error is Refusal) {
            throw ProviderError.from(transport: error)
        }
    }

    /// Turns a failure into the error the app shows. An invalid user ends the sign-in only
    /// if a refresh confirms it.
    private func fail(_ failure: Responses.Failure) async throws -> Never {
        switch failure {
        case .unsupported(let param):
            if param?.hasPrefix("text") == true { throw Refusal.schema }
            throw ProviderError.unsupported(param)
        case .invalidUser:
            try await account.confirm()
            throw ProviderError.unavailable
        case .error(let error):
            throw error
        }
    }
}

/// The Responses API's request and answer, as plain rules.
public enum Responses {
    public static func request(_ request: ModelRequest, access: String, withSchema: Bool) -> HTTPRequest {
        var instructions = request.instructions
        var body: [String: Any] = [
            "model": request.model,
            "input": [["role": "user", "content": request.input]],
            "store": false,
            "stream": true,
        ]
        if let schema = request.schema {
            if withSchema, let parsed = try? JSONSerialization.jsonObject(with: Data(schema.json.utf8)) {
                body["text"] = ["format": ["type": "json_schema", "name": schema.name, "schema": parsed, "strict": true]]
            } else {
                instructions += "\nReply with JSON only, matching this JSON schema: \(schema.json)"
            }
        }
        body["instructions"] = instructions
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return HTTPRequest(method: "POST", url: URL(string: ChatGPT.api + "/responses")!,
                           headers: ["Authorization": "Bearer \(access)", "Content-Type": "application/json",
                                     "Accept": "text/event-stream"],
                           body: data)
    }

    public enum Failure: Equatable, Sendable {
        case unsupported(String?)
        case invalidUser
        case error(ProviderError)
    }

    /// An error by OpenAI's code (`error.code`), or by the HTTP status when there is none
    /// (`{"detail": …}` before the stream is diagnostic text, never read as a code).
    public static func failure(code: String?, param: String? = nil, status: Int?) -> Failure {
        switch code {
        case "subscription_sharing_user_not_eligible": return .error(.notEligible)
        case "subscription_sharing_usage_limit_exceeded": return .error(.usageLimit)
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": return .error(.unavailable)
        case "subscription_sharing_unsupported_capability": return .unsupported(param)
        case "subscription_sharing_invalid_user": return .invalidUser
        case "subscription_sharing_route_not_supported", "invalid_client": return .error(.bug(code!))
        case let code? where code.hasPrefix("chatpass_v2_"): return .error(.bug(code))
        case let code?: return .error(.failed(code))
        case nil: break
        }
        switch status {
        case 401: return .invalidUser
        case 429: return .error(.usageLimit)
        case 503: return .error(.unavailable)
        case let status?: return .error(.failed("http_\(status)"))
        case nil: return .error(.failed("unknown_error"))
        }
    }

    static func failure(status: Int, body: Data) -> Failure {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        return failure(code: error?["code"] as? String, param: error?["param"] as? String, status: status)
    }

    public enum Event: Equatable, Sendable {
        case text(String)
        case completed
        case failed(Failure)
        case incomplete
    }

    /// One server-sent event line; nil for anything Clew does not use.
    public static func event(_ line: String) -> Event? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).drop { $0 == " " }
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        switch type {
        case "response.output_text.delta": return (json["delta"] as? String).map(Event.text)
        case "response.completed": return .completed
        case "response.incomplete": return .incomplete
        case "response.failed", "error":
            let error = (json["response"] as? [String: Any])?["error"] as? [String: Any]
                ?? json["error"] as? [String: Any] ?? json
            return .failed(failure(code: error["code"] as? String ?? "unknown_error", param: error["param"] as? String,
                                   status: nil))
        default: return nil
        }
    }
}

/// A model the plan can use.
public struct ChatGPTModel: Sendable, Equatable, Codable {
    public var slug: String
    public var displayName: String
    public init(slug: String, displayName: String) {
        self.slug = slug
        self.displayName = displayName
    }
}

public enum ChatGPTModels {
    public static func request(access: String) -> HTTPRequest {
        HTTPRequest(url: URL(string: ChatGPT.api + "/models")!, headers: ["Authorization": "Bearer \(access)"])
    }

    /// The listed models, in OpenAI's order (the first is the default).
    public static func parse(_ response: HTTPResponse) throws -> [ChatGPTModel] {
        guard response.status == 200 else {
            if case .error(let error) = Responses.failure(status: response.status, body: response.body) { throw error }
            throw ProviderError.failed("http_\(response.status)")
        }
        let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        return (json?["models"] as? [[String: Any]] ?? []).compactMap { item in
            guard item["visibility"] as? String == "list", let slug = item["slug"] as? String, !slug.isEmpty else {
                return nil
            }
            return ChatGPTModel(slug: slug, displayName: item["display_name"] as? String ?? slug)
        }
    }

    /// Reads the list with a valid access token.
    public static func list(_ account: ChatGPTAccount, _ transport: HTTPTransport) async throws -> [ChatGPTModel] {
        let access = try await account.access()
        do { return try parse(try await transport.send(request(access: access))) } catch let error as ProviderError {
            throw error
        } catch { throw ProviderError.from(transport: error) }
    }
}
