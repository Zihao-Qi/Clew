import ClewAI
import Foundation

/// One job: a few lines of instructions, an input snapshot, a typed output that Swift
/// checks before anything is shown (docs/AGENT.md §2, §5). A job never sees the store.
public protocol Job: Sendable {
    associatedtype Input: Encodable & Sendable
    associatedtype Output: Sendable
    static var name: String { get }
    var instructions: String { get }
    var schema: JSONSchema? { get }
    /// Reads and checks the answer; nil fields of `JobFailure` say why it was refused.
    func validate(_ text: String, input: Input) -> Result<Output, JobFailure>
}

/// Why a job showed nothing. Debug codes only, never any of the answer's text (§5).
public struct JobFailure: Error, Equatable, Sendable {
    public enum Reason: String, Sendable, Codable {
        case schema, tooLong, empty, banned, duplicate, none
    }
    /// The provider's error, if the request failed.
    public var provider: ProviderError?
    /// The checks that refused items or the whole answer.
    public var reasons: Set<Reason>

    public init(provider: ProviderError? = nil, reasons: Set<Reason> = []) {
        self.provider = provider
        self.reasons = reasons
    }

    /// A short code for the debug log.
    public var code: String {
        if let provider { return "\(provider)" }
        return reasons.map(\.rawValue).sorted().joined(separator: ",")
    }
}

/// What the debug log keeps of one run (§9): never text sent or received, never a token.
public struct JobRecord: Sendable, Equatable {
    public var job: String
    public var model: String
    public var inputBytes: Int
    public var seconds: Double
    public var outcome: String
    public var requestId: String?
}

public enum Agent {
    /// One request, one answer, no retry (a retry spends the person's plan). The answer
    /// must come within `timeout`, or it is a failure.
    public static func run<J: Job>(_ job: J, input: J.Input, model: String, provider: Provider,
                                   timeout: Duration = .seconds(30),
                                   log: @Sendable (JobRecord) -> Void = { _ in }) async -> Result<J.Output, JobFailure> {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = String(decoding: (try? encoder.encode(input)) ?? Data(), as: UTF8.self)
        let request = ModelRequest(model: model, instructions: job.instructions, input: text, schema: job.schema)
        let started = ContinuousClock.now
        var requestId: String?
        func record(_ outcome: String) {
            let elapsed = ContinuousClock.now - started
            log(JobRecord(job: J.name, model: model, inputBytes: text.utf8.count,
                          seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                          outcome: outcome, requestId: requestId))
        }
        do {
            let answer = try await withTimeout(timeout) { try await provider.answer(request) }
            requestId = answer.requestId
            let result = job.validate(answer.text, input: input)
            switch result {
            case .success: record("ok")
            case .failure(let failure): record(failure.code)
            }
            return result
        } catch is CancellationError {
            record("cancelled")
            return .failure(JobFailure(provider: nil, reasons: []))
        } catch {
            let provider = error as? ProviderError ?? .failed("unknown")
            record("\(provider)")
            return .failure(JobFailure(provider: provider))
        }
    }

    /// Runs `work`, or throws `ProviderError.timedOut` once `timeout` passes. Cancelling the
    /// caller cancels the work.
    static func withTimeout<T: Sendable>(_ timeout: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProviderError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }
}
