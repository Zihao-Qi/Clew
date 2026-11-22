import Foundation

/// What a job asks a model (docs/AGENT.md §2).
public struct ModelRequest: Sendable, Equatable {
    public var model: String
    /// The job's few lines of instructions.
    public var instructions: String
    /// The job's input snapshot, as text (JSON).
    public var input: String
    /// The output's JSON schema, when the job has one (structured output).
    public var schema: JSONSchema?

    public init(model: String, instructions: String, input: String, schema: JSONSchema? = nil) {
        self.model = model
        self.instructions = instructions
        self.input = input
        self.schema = schema
    }
}

/// A named JSON schema, as JSON text.
public struct JSONSchema: Sendable, Equatable {
    public var name: String
    public var json: String
    public init(name: String, json: String) {
        self.name = name
        self.json = json
    }
}

public enum ProviderEvent: Sendable, Equatable {
    /// The request was accepted; OpenAI's request id when it gave one.
    case started(requestId: String?)
    case text(String)
    /// The answer is complete (OpenAI: `response.completed`). Only this is success.
    case done
}

/// Why a request failed. Each maps to one plain message in the app (SPEC "Suggest steps").
public enum ProviderError: Error, Equatable, Sendable {
    /// Nobody is signed in.
    case notSignedIn
    /// The provider ended the sign-in; the person must sign in again.
    case signInEnded
    /// Signed in, but the plan permission was not granted.
    case noPlanPermission
    /// The plan can't be used for this (OpenAI: not eligible).
    case notEligible
    /// The plan's usage limit is reached.
    case usageLimit
    /// Temporarily unavailable (503, usage or user unavailable): try again later.
    case unavailable
    case offline
    case timedOut
    /// The model refused a capability (`error.param`), after the one retry without it.
    case unsupported(String?)
    /// The stream ended without `response.completed`, or said incomplete.
    case incomplete
    /// A failure Clew should never see if it is built right (debug log): the code.
    case bug(String)
    /// Any other failure: the code or HTTP status, never the text.
    case failed(String)
}

/// One model service (docs/AGENT.md §2). The ChatGPT plan first; others behind the same
/// protocol later (§10). Cancelling the consuming task cancels the request.
public protocol Provider: Sendable {
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ProviderEvent, Error>
}

public struct ProviderAnswer: Sendable, Equatable {
    public var text: String
    public var requestId: String?
}

extension Provider {
    /// The whole answer, once complete; throws a `ProviderError` otherwise.
    public func answer(_ request: ModelRequest) async throws -> ProviderAnswer {
        var text = "", requestId: String?, completed = false
        for try await event in stream(request) {
            switch event {
            case .started(let id): requestId = id
            case .text(let delta): text += delta
            case .done: completed = true
            }
        }
        try Task.checkCancellation()
        guard completed else { throw ProviderError.incomplete }
        return ProviderAnswer(text: text, requestId: requestId)
    }
}
