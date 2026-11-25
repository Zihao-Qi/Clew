import ClewAI
import Foundation

/// Notes to tasks (AI-5; SPEC "Notes to tasks"): a note becomes a suggested task (a title,
/// Today or Later, a reason, steps only when the note lists them) or is a thought to keep.
/// Nothing is made without the person's click; nothing about notes is remembered.
public enum NoteSuggestion: Sendable, Equatable {
    case task(title: String, today: Bool, reason: String, steps: [String])
    case thought

    public static let longest = 80
    public static let mostSteps = 5

    /// One item of an answer, as the schema gives it.
    struct Item: Decodable {
        var id: String?
        var kind: String
        var title: String?
        var `where`: String?
        var reason: String?
        var steps: [String]

        static let keys: Set<String> = ["kind", "title", "where", "reason", "steps"]
        enum CodingKeys: String, CodingKey { case id, kind, title, `where`, reason, steps }
        init(from decoder: Decoder) throws {
            let any = try decoder.container(keyedBy: AnyKey.self)
            let names = Set(any.allKeys.map(\.stringValue))
            guard names == Self.keys || names == Self.keys.union(["id"]) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "fields"))
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            kind = try c.decode(String.self, forKey: .kind)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            `where` = try c.decodeIfPresent(String.self, forKey: .where)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            steps = try c.decode([String].self, forKey: .steps)
        }
    }

    /// The checks (SPEC "Notes to tasks": Checked before showing). A banned phrase the
    /// note itself carries is allowed; a failing step is dropped, a failing title or
    /// reason refuses the task. Nil: refused, with why in `refused`.
    static func checked(_ item: Item, note: String, refused: inout Set<JobFailure.Reason>) -> NoteSuggestion? {
        switch item.kind {
        case "thought":
            return .thought
        case "task":
            break
        default:
            refused.insert(.schema)
            return nil
        }
        let allowed = [note]
        func line(_ raw: String?) -> String? {
            let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { refused.insert(.empty); return nil }
            if text.contains(where: \.isNewline) { refused.insert(.lineBreak); return nil }
            if text.count > longest { refused.insert(.tooLong); return nil }
            if Banned.trips(text, allowing: allowed) { refused.insert(.banned); return nil }
            return text
        }
        guard let title = line(item.title), let reason = line(item.reason) else { return nil }
        guard let place = item.where, place == "today" || place == "later" else {
            refused.insert(.schema)
            return nil
        }
        var steps: [String] = [], seen = Set<String>()
        for raw in item.steps {
            let step = SuggestSteps.cleaned(raw)
            if step.isEmpty { refused.insert(.empty); continue }
            if step.contains(where: \.isNewline) { refused.insert(.lineBreak); continue }
            if step.count > longest { refused.insert(.tooLong); continue }
            if Banned.trips(step, allowing: allowed) { refused.insert(.banned); continue }
            guard seen.insert(SuggestSteps.key(step)).inserted else { refused.insert(.duplicate); continue }
            steps.append(step)
            if steps.count == mostSteps { break }
        }
        return .task(title: title, today: place == "today", reason: reason, steps: steps)
    }

    /// Nullable fields as anyOf, as strict mode needs (as Memory's note).
    static let itemSchema = #"{"type":"object","properties":{"kind":{"type":"string","enum":["task","thought"]},"title":{"anyOf":[{"type":"string"},{"type":"null"}]},"where":{"anyOf":[{"type":"string","enum":["today","later"]},{"type":"null"}]},"reason":{"anyOf":[{"type":"string"},{"type":"null"}]},"steps":{"type":"array","items":{"type":"string"}}},"required":["kind","title","where","reason","steps"],"additionalProperties":false}"#

    static let instructions = """
        You help someone turn a note they wrote in a hurry into one clear task. Give the \
        task's title: short and concrete, a verb first where natural, at most 12 words. \
        Give steps only when the note itself lists several things to do; otherwise none. \
        Choose today only when the note says or clearly means today; otherwise later. \
        Give a short, kind reason (under 12 words), never pushy, urgent or guilt-inducing. \
        A note that is not something to do (a reflection, a quote, an idea to keep) is a \
        thought: kind "thought", with null title, where and reason and no steps. Reply in \
        the note's own language.
        """
}

/// ✨ on one note: that note's text only (SPEC "Notes to tasks": What is sent).
public struct NoteToTask: Job {
    public static let name = "noteToTask"

    public struct Input: Encodable, Sendable, Equatable {
        public var weekday: String
        public var time: String
        public var note: String

        public init(note: String, at now: Date, calendar: Calendar) {
            let event = ActivityEvent.make(.taskTicked, at: now, calendar: calendar, task: "", typed: true)
            weekday = event.weekday
            time = event.time
            self.note = note
        }

        enum Keys: String, CodingKey { case now, note }
        enum NowKeys: String, CodingKey { case weekday, time }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            var now = c.nestedContainer(keyedBy: NowKeys.self, forKey: .now)
            try now.encode(weekday, forKey: .weekday)
            try now.encode(time, forKey: .time)
            try c.encode(note, forKey: .note)
        }
    }

    public init() {}

    public let instructions = NoteSuggestion.instructions
    public func carriesNotes(_ input: Input) -> Bool { true }

    public var schema: JSONSchema? { JSONSchema(name: "note_task", json: NoteSuggestion.itemSchema) }

    public func validate(_ text: String, input: Input) -> Result<NoteSuggestion, JobFailure> {
        guard let item = try? JSONDecoder().decode(NoteSuggestion.Item.self, from: Data(SuggestSteps.unfenced(text).utf8)),
              item.id == nil else {
            return .failure(JobFailure(reasons: [.schema]))
        }
        var refused = Set<JobFailure.Reason>()
        guard let suggestion = NoteSuggestion.checked(item, note: input.note, refused: &refused) else {
            return .failure(JobFailure(reasons: refused.union([.none])))
        }
        return .success(suggestion)
    }
}

/// Sort with ✨: every open note (up to 20, newest first) with a short id (q1…q20).
public struct SortNotes: Job {
    public static let name = "sortNotes"
    public static let sentAtMost = 20

    public struct Note: Encodable, Sendable, Equatable {
        public var id: String
        public var text: String
    }

    public struct Input: Encodable, Sendable, Equatable {
        public var weekday: String
        public var time: String
        public var notes: [Note]

        enum Keys: String, CodingKey { case now, notes }
        enum NowKeys: String, CodingKey { case weekday, time }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            var now = c.nestedContainer(keyedBy: NowKeys.self, forKey: .now)
            try now.encode(weekday, forKey: .weekday)
            try now.encode(time, forKey: .time)
            try c.encode(notes, forKey: .notes)
        }
    }

    /// What is sent and how its short ids map back: the first `sentAtMost` notes in the
    /// order given (newest first).
    public static func input(_ notes: [(id: UUID, text: String)], at now: Date, calendar: Calendar)
        -> (input: Input, ids: [String: UUID]) {
        var ids: [String: UUID] = [:], sent: [Note] = []
        for (n, note) in notes.prefix(sentAtMost).enumerated() {
            let id = "q\(n + 1)"
            ids[id] = note.id
            sent.append(Note(id: id, text: note.text))
        }
        let event = ActivityEvent.make(.taskTicked, at: now, calendar: calendar, task: "", typed: true)
        return (Input(weekday: event.weekday, time: event.time, notes: sent), ids)
    }

    public let ids: [String: UUID]
    public init(ids: [String: UUID]) { self.ids = ids }

    public var instructions: String {
        NoteSuggestion.instructions + " Do this for each note given, by its id; reply in each note's own language."
    }
    public func carriesNotes(_ input: Input) -> Bool { true }

    public var schema: JSONSchema? {
        let item = NoteSuggestion.itemSchema
            .replacingOccurrences(of: #"{"type":"object","properties":{"kind""#, with: #"{"type":"object","properties":{"id":{"type":"string"},"kind""#)
            .replacingOccurrences(of: #""required":["kind""#, with: #""required":["id","kind""#)
        return JSONSchema(name: "note_tasks", json: #"{"type":"object","properties":{"notes":{"type":"array","items":"# + item + #"}},"required":["notes"],"additionalProperties":false}"#)
    }

    struct Answer: Decodable {
        var notes: [NoteSuggestion.Item]
        enum CodingKeys: String, CodingKey { case notes }
        init(from decoder: Decoder) throws {
            let any = try decoder.container(keyedBy: AnyKey.self)
            guard any.allKeys.map(\.stringValue) == ["notes"] else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "fields"))
            }
            notes = try decoder.container(keyedBy: CodingKeys.self).decode([NoteSuggestion.Item].self, forKey: .notes)
        }
    }

    /// Each note's suggestion; notes left out or failing get none. None at all: a failure.
    public func validate(_ text: String, input: Input) -> Result<[UUID: NoteSuggestion], JobFailure> {
        guard let answer = try? JSONDecoder().decode(Answer.self, from: Data(SuggestSteps.unfenced(text).utf8)) else {
            return .failure(JobFailure(reasons: [.schema]))
        }
        let texts = Dictionary(uniqueKeysWithValues: input.notes.map { ($0.id, $0.text) })
        var kept: [UUID: NoteSuggestion] = [:], refused = Set<JobFailure.Reason>()
        for item in answer.notes {
            guard let id = item.id, let noteId = ids[id], let note = texts[id] else { refused.insert(.unknownId); continue }
            // The first passing entry for an id is kept.
            guard kept[noteId] == nil else { refused.insert(.duplicate); continue }
            if let suggestion = NoteSuggestion.checked(item, note: note, refused: &refused) { kept[noteId] = suggestion }
        }
        return kept.isEmpty ? .failure(JobFailure(reasons: refused.union([.none]))) : .success(kept)
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
