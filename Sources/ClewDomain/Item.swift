import Foundation

/// SPEC's "Once / Repeating / Counted goal" map to `once | habit | goal`; `link` is a
/// saved link (ARCHITECTURE §4.2).
public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case once, habit, goal, link
}

public enum ItemState: String, Codable, Sendable, CaseIterable {
    /// Eligible for Today.
    case active
    /// In the hidden Later pile.
    case later
    case paused
    case archived
}

/// Who made a write. Every write is attributed. `agent` is deliberately absent: the
/// agent never writes user data (ADR-4).
public enum Source: String, Codable, Sendable, CaseIterable {
    case user
    case notification
    case extensionYouTube = "extension.youtube"
    case extensionX = "extension.x"
    case dayflow
    case `import`
}

/// Where an item's title came from. A fetched title was written by a stranger, so the
/// future AI coach treats it as untrusted text (AGENT.md §4).
public enum TitleOrigin: String, Codable, Sendable, CaseIterable {
    case typed
    case fetched
}

/// How an item's progress is measured. Stored as versioned JSON.
public enum ProgressSpec: Hashable, Sendable {
    case none
    /// A counted goal: lifetime total of check-in amounts out of `target`.
    case counter(target: Int)

    public var target: Int? {
        if case .counter(let target) = self { return target }
        return nil
    }
}

/// When a habit or goal is due. Stored as versioned JSON, so adding a case needs no
/// schema migration (ARCHITECTURE §4.4). The day a once-item is meant for lives only
/// in `Item.plannedDay`; there is deliberately no `.once(day)` case.
public enum Schedule: Hashable, Sendable {
    case daily
    case weekdays(Set<Weekday>)
    case timesPerWeek(Int)
    case unscheduled
}

/// A definition: what you intend. Mutable, soft-deleted (ADR-2).
public struct Item: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: ItemKind
    public var title: String
    public var titleOrigin: TitleOrigin
    public var url: URL?
    public var note: String?
    public var parentId: UUID?
    public var schedule: Schedule
    public var progress: ProgressSpec
    public var state: ItemState
    public var plannedDay: LocalDay?
    public var sortKey: Double
    public var source: Source
    public var externalRef: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID, kind: ItemKind, title: String, titleOrigin: TitleOrigin = .typed, url: URL? = nil, note: String? = nil,
        parentId: UUID? = nil, schedule: Schedule, progress: ProgressSpec, state: ItemState,
        plannedDay: LocalDay? = nil, sortKey: Double, source: Source, externalRef: String? = nil,
        createdAt: Date, updatedAt: Date, deletedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.titleOrigin = titleOrigin
        self.url = url
        self.note = note
        self.parentId = parentId
        self.schedule = schedule
        self.progress = progress
        self.state = state
        self.plannedDay = plannedDay
        self.sortKey = sortKey
        self.source = source
        self.externalRef = externalRef
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

// MARK: - Versioned JSON for value-typed columns

extension Schedule: Codable {
    private enum CodingKeys: String, CodingKey { case v, type, days, times }
    private static let version = 1

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .v)
        guard v == Self.version else {
            throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "Unknown schedule version \(v)")
        }
        switch try c.decode(String.self, forKey: .type) {
        case "daily": self = .daily
        case "weekdays": self = .weekdays(Set(try c.decode([Weekday].self, forKey: .days)))
        case "timesPerWeek": self = .timesPerWeek(try c.decode(Int.self, forKey: .times))
        case "unscheduled": self = .unscheduled
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown schedule \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.version, forKey: .v)
        switch self {
        case .daily:
            try c.encode("daily", forKey: .type)
        case .weekdays(let days):
            try c.encode("weekdays", forKey: .type)
            try c.encode(days.sorted(), forKey: .days)
        case .timesPerWeek(let n):
            try c.encode("timesPerWeek", forKey: .type)
            try c.encode(n, forKey: .times)
        case .unscheduled:
            try c.encode("unscheduled", forKey: .type)
        }
    }
}

extension ProgressSpec: Codable {
    private enum CodingKeys: String, CodingKey { case v, type, target }
    private static let version = 1

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .v)
        guard v == Self.version else {
            throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "Unknown progress version \(v)")
        }
        switch try c.decode(String.self, forKey: .type) {
        case "none": self = .none
        case "counter": self = .counter(target: try c.decode(Int.self, forKey: .target))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown progress \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.version, forKey: .v)
        switch self {
        case .none:
            try c.encode("none", forKey: .type)
        case .counter(let target):
            try c.encode("counter", forKey: .type)
            try c.encode(target, forKey: .target)
        }
    }
}
