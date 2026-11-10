import ClewDomain
import Foundation

/// Storage port. ClewStore (GRDB) implements it; tests use an in-memory fake.
///
/// `write` runs its body in **one transaction**: either every change lands or none
/// does. Implementations must reject updates to fact substance and deletes of facts.
public protocol ClewStore: Sendable {
    func read<T>(_ body: (any StoreReader) throws -> T) throws -> T
    func write<T>(_ body: (any StoreWriter) throws -> T) throws -> T
    /// Calls `onChange` after every committed write that touches items or facts,
    /// whoever made it. Keep the returned token alive to keep observing.
    func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> any StoreObservation
}

public protocol StoreObservation: AnyObject, Sendable {
    func cancel()
}

public protocol StoreReader {
    func item(id: UUID) throws -> Item?
    /// Items in any of `states`, excluding soft-deleted ones.
    func items(inStates states: Set<ItemState>) throws -> [Item]
    func checkIn(id: UUID) throws -> CheckIn?
    /// Non-voided check-ins of `itemIds` with `localDay >= from`.
    func checkIns(itemIds: [UUID], from: LocalDay) throws -> [CheckIn]
    /// Start of each goal's current round: the latest non-voided `GoalRound`. Items
    /// still in round 1 are missing.
    func roundStarts(itemIds: [UUID]) throws -> [UUID: Date]
    /// Sum of non-voided check-in amounts per item since its current round started
    /// (all time if it has no round). Missing means 0.
    func progressAmounts(itemIds: [UUID]) throws -> [UUID: Int]
    func plans(itemId: UUID) throws -> [Plan]
    func goalRounds(itemId: UUID) throws -> [GoalRound]
    func maxSortKey() throws -> Double?
    /// Days that have at least one non-voided check-in, from `from` onward.
    func activeDays(from: LocalDay) throws -> Set<LocalDay>
    /// Every row, including soft-deleted items and voided facts, for export.
    func allRecords() throws -> ExportRecords
    /// Reminders that are not soft-deleted.
    func reminders() throws -> [Reminder]
    /// A setting's stored JSON, or nil if never set.
    func setting(_ key: String) throws -> String?
    /// Non-voided "still want this?" answers for these items.
    func laterReviews(itemIds: [UUID]) throws -> [LaterReview]
    /// How many items the user let go (non-voided), all time. Let-gos made by an
    /// import (an item that left an external list) are not the user's, so not counted.
    func letGoCount() throws -> Int
    /// Every item from `source`, soft-deleted ones included (imports are keyed by
    /// `(source, externalRef)`).
    func items(source: Source) throws -> [Item]
}

/// Everything Clew stores, as it is stored.
public struct ExportRecords: Hashable, Sendable, Codable {
    public var items: [Item]
    public var checkIns: [CheckIn]
    public var plans: [Plan]
    public var goalRounds: [GoalRound]
    public var reminders: [Reminder]
    public var settings: [SettingRecord]
    public var laterReviews: [LaterReview]

    public init(items: [Item], checkIns: [CheckIn], plans: [Plan], goalRounds: [GoalRound],
                reminders: [Reminder] = [], settings: [SettingRecord] = [], laterReviews: [LaterReview] = []) {
        self.items = items
        self.checkIns = checkIns
        self.plans = plans
        self.goalRounds = goalRounds
        self.reminders = reminders
        self.settings = settings
        self.laterReviews = laterReviews
    }

    private enum CodingKeys: String, CodingKey {
        case items, checkIns, plans, goalRounds, reminders, settings, laterReviews
    }

    /// `reminders` and `settings` arrived after the first exports; older files read as empty.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            items: try c.decode([Item].self, forKey: .items),
            checkIns: try c.decode([CheckIn].self, forKey: .checkIns),
            plans: try c.decode([Plan].self, forKey: .plans),
            goalRounds: try c.decode([GoalRound].self, forKey: .goalRounds),
            reminders: try c.decodeIfPresent([Reminder].self, forKey: .reminders) ?? [],
            settings: try c.decodeIfPresent([SettingRecord].self, forKey: .settings) ?? [],
            laterReviews: try c.decodeIfPresent([LaterReview].self, forKey: .laterReviews) ?? []
        )
    }
}

public protocol StoreWriter: StoreReader {
    func insert(_ item: Item) throws
    /// Replaces the definition row with the same id.
    func update(_ item: Item) throws
    func insert(_ checkIn: CheckIn) throws
    /// Sets `voidedAt`/`voidReason`. Voids are monotonic: voiding twice is an error.
    func voidCheckIn(id: UUID, at: Date, reason: String) throws
    /// Sets `rating`/`ratedAt`, the check-in's only other mutable fields (§4.2).
    func rateCheckIn(id: UUID, rating: Int, at: Date) throws
    func insert(_ plan: Plan) throws
    func insert(_ round: GoalRound) throws
    /// Inserts, or replaces the row with the same id.
    func save(_ reminder: Reminder) throws
    func saveSetting(_ key: String, json: String, updatedAt: Date) throws
    func insert(_ review: LaterReview) throws
    /// Sets the review's `voidedAt`. Voids are monotonic: voiding twice is an error.
    func voidLaterReview(id: UUID, at: Date) throws
}

/// A row of the `settings` table: a definition with last-writer-wins by `updatedAt`.
public struct SettingRecord: Hashable, Sendable, Codable {
    public var key: String
    public var value: String
    public var updatedAt: Date

    public init(key: String, value: String, updatedAt: Date) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
    }
}
