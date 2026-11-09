import Foundation

/// A fact: something that happened. Inserted, never updated in substance, never
/// deleted (ADR-2). The only fields changed after insert are `rating`/`ratedAt`
/// (last writer wins by `ratedAt`) and `voidedAt`/`voidReason` (monotonic), per
/// ARCHITECTURE §4.2 and §8.
public struct CheckIn: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let itemId: UUID
    /// Computed once at creation from the injected clock, zone and rollover hour.
    public let localDay: LocalDay
    /// UTC instant.
    public let at: Date
    public let timeZoneId: String
    public let amount: Int
    public var rating: Int?
    public var ratedAt: Date?
    public let source: Source
    public var voidedAt: Date?
    public var voidReason: String?

    public init(
        id: UUID, itemId: UUID, localDay: LocalDay, at: Date, timeZoneId: String,
        amount: Int = 1, rating: Int? = nil, ratedAt: Date? = nil, source: Source,
        voidedAt: Date? = nil, voidReason: String? = nil
    ) {
        self.id = id
        self.itemId = itemId
        self.localDay = localDay
        self.at = at
        self.timeZoneId = timeZoneId
        self.amount = amount
        self.rating = rating
        self.ratedAt = ratedAt
        self.source = source
        self.voidedAt = voidedAt
        self.voidReason = voidReason
    }

    public var isVoided: Bool { voidedAt != nil }
}

/// A counted goal's next round: "30/30 reached, go again". Check-ins before
/// `startedAt` belong to earlier rounds, so the bar starts from zero while every
/// check-in, and every finished round, stays in the history (for rewards, v1.3).
/// Round 1 has no row; it starts when the goal is created.
public struct GoalRound: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let itemId: UUID
    public let startedAt: Date
    public let localDay: LocalDay
    /// The target when the round began. The item's target may be raised later.
    public let target: Int
    public let source: Source
    public var voidedAt: Date?

    public init(id: UUID, itemId: UUID, startedAt: Date, localDay: LocalDay, target: Int, source: Source,
                voidedAt: Date? = nil) {
        self.id = id
        self.itemId = itemId
        self.startedAt = startedAt
        self.localDay = localDay
        self.target = target
        self.source = source
        self.voidedAt = voidedAt
    }
}

/// "Picked for today", kept as history so pick history survives later re-planning.
public struct Plan: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let itemId: UUID
    public let localDay: LocalDay
    public let at: Date
    public let source: Source
    public var voidedAt: Date?

    public init(id: UUID, itemId: UUID, localDay: LocalDay, at: Date, source: Source, voidedAt: Date? = nil) {
        self.id = id
        self.itemId = itemId
        self.localDay = localDay
        self.at = at
        self.source = source
        self.voidedAt = voidedAt
    }
}
