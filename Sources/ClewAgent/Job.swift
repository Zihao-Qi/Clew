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
    /// True when the input carries text the person did not type (§4): then no activity
    /// is sent and the answer's note change is ignored (§7).
    func untrusted(_ input: Input) -> Bool
}

extension Job {
    public func untrusted(_ input: Input) -> Bool { false }
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
    /// The note change's action or its failure code (§7), if memory was sent.
    public var note: String? = nil
}

/// One run with memory (§7): the job's own result, the note change judged apart from it,
/// and the activity events that now count as sent.
public struct JobRun<Output: Sendable>: Sendable {
    public var result: Result<Output, JobFailure>
    /// nil when no memory was sent or the change is ignored (untrusted input, no answer).
    public var note: Result<ProposedNote?, NoteFailure>?
    /// Only after a completed answer, and only the events it carried.
    public var sentEvents: Set<UUID>
}

public enum Agent {
    /// One request, one answer, no retry (a retry spends the person's plan). The answer
    /// must come within `timeout`, or it is a failure.
    public static func run<J: Job>(_ job: J, input: J.Input, model: String, provider: Provider,
                                   timeout: Duration = .seconds(30),
                                   log: @Sendable (JobRecord) -> Void = { _ in }) async -> Result<J.Output, JobFailure> {
        await run(job, input: input, memory: nil, model: model, provider: provider, timeout: timeout, log: log).result
    }

    /// The same, with the person's notes and recent activity (§7). The answer's `note`
    /// is split off and judged on its own; the job sees only its own fields.
    public static func run<J: Job>(_ job: J, input: J.Input, memory: MemoryContext?, model: String,
                                   provider: Provider, timeout: Duration = .seconds(30),
                                   log: @Sendable (JobRecord) -> Void = { _ in }) async -> JobRun<J.Output> {
        let untrusted = job.untrusted(input)
        var memory = memory
        if untrusted { memory?.events = [] }   // they wait for a job with typed input
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let own = (try? encoder.encode(input)) ?? Data()
        var text = String(decoding: own, as: UTF8.self)
        var instructions = job.instructions
        var schema = job.schema
        var sent: [String: Note] = [:]
        if let memory, var object = (try? JSONSerialization.jsonObject(with: own)) as? [String: Any] {
            let encoded = Memory.encoded(memory)
            sent = encoded.sent
            object["memory"] = encoded.json
            text = json(object)
            instructions += "\n" + Memory.instructions
            schema = schema.map { withNote($0) }
        }
        let request = ModelRequest(model: model, instructions: instructions, input: text, schema: schema)
        let started = ContinuousClock.now
        var requestId: String?
        func record(_ outcome: String, note: String? = nil) {
            let elapsed = ContinuousClock.now - started
            log(JobRecord(job: J.name, model: model, inputBytes: text.utf8.count,
                          seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                          outcome: outcome, requestId: requestId, note: note))
        }
        do {
            let answer = try await withTimeout(timeout) { try await provider.answer(request) }
            requestId = answer.requestId
            var ownText = answer.text
            var note: Result<ProposedNote?, NoteFailure>?
            if memory != nil {
                let split = splitNote(answer.text)
                ownText = split.rest
                note = split.note.map { $0.map { ProposedNote(change: $0, sent: sent) } }
                if untrusted { note = nil }
            }
            let result = job.validate(ownText, input: input)
            let noteCode: String? = switch note {
            case .success(let p?): p.change.action.rawValue
            case .success(nil): "none"
            case .failure(let f): f.rawValue
            case nil: nil
            }
            switch result {
            case .success: record("ok", note: noteCode)
            case .failure(let failure): record(failure.code, note: noteCode)
            }
            return JobRun(result: result, note: note, sentEvents: Set((memory?.events ?? []).map(\.id)))
        } catch is CancellationError {
            record("cancelled")
            return JobRun(result: .failure(JobFailure(provider: nil, reasons: [])), note: nil, sentEvents: [])
        } catch {
            let provider = error as? ProviderError ?? .failed("unknown")
            record("\(provider)")
            return JobRun(result: .failure(JobFailure(provider: provider)), note: nil, sentEvents: [])
        }
    }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    /// The job's schema with the required, nullable `note` beside its own fields.
    static func withNote(_ schema: JSONSchema) -> JSONSchema {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(schema.json.utf8))) as? [String: Any] else {
            return schema
        }
        var properties = object["properties"] as? [String: Any] ?? [:]
        properties["note"] = Memory.noteSchema
        object["properties"] = properties
        object["required"] = (object["required"] as? [String] ?? []) + ["note"]
        return JSONSchema(name: schema.name, json: json(object))
    }

    /// Splits `note` off an answer: the rest goes to the job, the note is decoded alone.
    /// An answer that is not a JSON object goes to the job whole (it fails there).
    static func splitNote(_ text: String) -> (rest: String, note: Result<NoteChange?, NoteFailure>) {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(SuggestSteps.unfenced(text).utf8)))
            as? [String: Any] else { return (text, .failure(.noteSchema)) }
        let note = Memory.decode(object["note"])
        object["note"] = nil
        return (json(object), note)
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
