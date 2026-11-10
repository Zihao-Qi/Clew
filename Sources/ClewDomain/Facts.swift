import Foundation

/// A fact: something that happened. Inserted, never updated in substance, never
/// deleted (ADR-2). The only fields changed after insert are `rating`/`ratedAt`
/// (last writer wins by `ratedAt`) and `voidedAt`/`voidReason` (monotonic), per
/// ARCHITECTURE §4.2 and §8.
public struct CheckIn: Hashable, Sendable, Identifiable, Codable {
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
public struct GoalRound: Hashable, Sendable, Identifiable, Codable {
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
public struct Plan: Hashable, Sendable, Identifiable, Codable {
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

/// "Still want this?" for a Later item that waited 6+ weeks (SPEC §5): the user kept it
/// (its 6 weeks start again) or let it go (a win, not a failure; the item is removed).
public struct LaterReview: Hashable, Sendable, Identifiable, Codable {
    public enum Decision: String, Codable, Sendable { case keep, letGo }

    public let id: UUID
    public let itemId: UUID
    public let decision: Decision
    public let at: Date
    public let localDay: LocalDay
    public let source: Source
    public var voidedAt: Date?

    public init(id: UUID, itemId: UUID, decision: Decision, at: Date, localDay: LocalDay, source: Source,
                voidedAt: Date? = nil) {
        self.id = id
        self.itemId = itemId
        self.decision = decision
        self.at = at
        self.localDay = localDay
        self.source = source
        self.voidedAt = voidedAt
    }
}

/// How long a Later item has waited, and whether to ask "still want this?".
public enum LaterAge {
    /// SPEC §5: items untouched for 6 weeks get a one-tap "still want this?".
    public static let askAfterDays = 42

    /// Days since the item was last touched: saved, edited, moved to Later, or kept.
    public static func daysWaiting(lastTouched: LocalDay, today: LocalDay) -> Int {
        max(0, today.ordinal - lastTouched.ordinal)
    }

    public static func asksStillWant(daysWaiting: Int) -> Bool {
        daysWaiting >= askAfterDays
    }
}

/// Time spent focusing on a task (SPEC decision 2026-11-10): one finished or stopped
/// focus timer, or time added by hand. A fact: inserted, never changed in substance,
/// removed only by voiding.
public struct FocusSession: Hashable, Sendable, Identifiable, Codable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Recorded by the focus timer.
        case timer
        /// Added by hand on the task's details.
        case manual
    }

    public let id: UUID
    public let itemId: UUID
    /// The day the time counts for (the timer's start; the day chosen by hand).
    public let localDay: LocalDay
    /// When it started (timer) or was added (by hand).
    public let at: Date
    public let minutes: Int
    public let kind: Kind
    public var voidedAt: Date?

    public init(id: UUID, itemId: UUID, localDay: LocalDay, at: Date, minutes: Int, kind: Kind, voidedAt: Date? = nil) {
        self.id = id
        self.itemId = itemId
        self.localDay = localDay
        self.at = at
        self.minutes = minutes
        self.kind = kind
        self.voidedAt = voidedAt
    }
}

/// A task placed on the day timeline (SPEC decision 2026-11-10). A definition, not a
/// fact: it moves and resizes, and is removed with a tombstone (`removedAt`). Its end
/// ticks the task once (`decidedAt`); see ARCHITECTURE §6 "Day timeline".
public struct TimeBlock: Hashable, Sendable, Identifiable, Codable {
    public let id: UUID
    public let itemId: UUID
    /// The Clew day it belongs to.
    public let localDay: LocalDay
    public var start: Date
    public var minutes: Int
    /// When it was placed: hand ticks from then on can cover it.
    public let placedAt: Date
    public var updatedAt: Date
    /// When its end passed and it ticked or skipped; nil while it waits.
    public var decidedAt: Date?
    /// Its own tick (`source = timeline`), if it made one.
    public var tickId: UUID?
    /// The hand tick it used instead; stays with the block.
    public var coverId: UUID?
    public var removedAt: Date?
    /// Placed by the task's slot, or by hand. A slot block never ticks by itself.
    public var origin: Origin
    /// When the user moved, resized or removed it by hand (a slot block is then today's
    /// own; Edit no longer moves it).
    public var touchedAt: Date?
    /// A slot block whose end passed asks "Done?" from then until answered or the day ends.
    public var askedAt: Date?
    /// A goal that reached its total while placed goes back to the list: its blocks are
    /// released and no longer hold it on the timeline.
    public var releasedAt: Date?

    public enum Origin: String, Codable, Sendable { case hand, slot }

    public init(id: UUID, itemId: UUID, localDay: LocalDay, start: Date, minutes: Int, placedAt: Date,
                updatedAt: Date, decidedAt: Date? = nil, tickId: UUID? = nil, coverId: UUID? = nil,
                removedAt: Date? = nil, origin: Origin = .hand, touchedAt: Date? = nil, askedAt: Date? = nil,
                releasedAt: Date? = nil) {
        self.id = id
        self.itemId = itemId
        self.localDay = localDay
        self.start = start
        self.minutes = minutes
        self.placedAt = placedAt
        self.updatedAt = updatedAt
        self.decidedAt = decidedAt
        self.tickId = tickId
        self.coverId = coverId
        self.removedAt = removedAt
        self.origin = origin
        self.touchedAt = touchedAt
        self.askedAt = askedAt
        self.releasedAt = releasedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, itemId, localDay, start, minutes, placedAt, updatedAt, decidedAt, tickId, coverId, removedAt,
             origin, touchedAt, askedAt, releasedAt
    }

    /// Exports from before slots have no origin: those blocks were placed by hand.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id), itemId: try c.decode(UUID.self, forKey: .itemId),
            localDay: try c.decode(LocalDay.self, forKey: .localDay), start: try c.decode(Date.self, forKey: .start),
            minutes: try c.decode(Int.self, forKey: .minutes), placedAt: try c.decode(Date.self, forKey: .placedAt),
            updatedAt: try c.decode(Date.self, forKey: .updatedAt),
            decidedAt: try c.decodeIfPresent(Date.self, forKey: .decidedAt),
            tickId: try c.decodeIfPresent(UUID.self, forKey: .tickId),
            coverId: try c.decodeIfPresent(UUID.self, forKey: .coverId),
            removedAt: try c.decodeIfPresent(Date.self, forKey: .removedAt),
            origin: try c.decodeIfPresent(Origin.self, forKey: .origin) ?? .hand,
            touchedAt: try c.decodeIfPresent(Date.self, forKey: .touchedAt),
            askedAt: try c.decodeIfPresent(Date.self, forKey: .askedAt),
            releasedAt: try c.decodeIfPresent(Date.self, forKey: .releasedAt))
    }

    public var end: Date { start.addingTimeInterval(TimeInterval(minutes * 60)) }
}

/// How much of a video was watched, as last seen on its site (ARCHITECTURE §4.2).
/// Latest state, not a fact: one row per item, and an older observation never
/// replaces a newer one. It never ticks anything (SPEC decision 2026-11-09).
public struct WatchProgress: Hashable, Sendable, Codable {
    public let itemId: UUID
    /// 0–1, in steps of 0.01.
    public var fraction: Double
    public var observedAt: Date
    public var source: Source

    public init(itemId: UUID, fraction: Double, observedAt: Date, source: Source) {
        self.itemId = itemId
        self.fraction = fraction
        self.observedAt = observedAt
        self.source = source
    }
}
