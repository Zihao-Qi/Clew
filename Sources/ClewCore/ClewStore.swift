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
    /// Live (not voided) plans for `day`, any item, oldest first (SPEC 2026-11-15: items
    /// moved to Today).
    func plans(on day: LocalDay) throws -> [Plan]
    /// Live plans for `day` and the days after it, any item, oldest first (SPEC
    /// 2026-11-17: a day for Later is a plan booked ahead).
    func plans(from day: LocalDay) throws -> [Plan]
    /// Items done on each day through `day` (SPEC 2026-11-18, `DoneCount`'s rule, counted
    /// in the store: one row a day, not one per +1): distinct items with a live check-in
    /// that day, items from a collection (by the item's source) left out, deleted kept.
    func doneByDay(through day: LocalDay) throws -> [LocalDay: Int]
    /// Every goal, deleted ones too.
    func goals() throws -> [Item]
    func goalRounds(itemId: UUID) throws -> [GoalRound]
    /// The highest sort key of any item, or live plan's Today key.
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
    /// Every item from `source`, soft-deleted ones included (imports are keyed by
    /// `(source, externalRef)`).
    func items(source: Source) throws -> [Item]
    /// The latest watch progress of these items; missing means none seen.
    func watchProgress(itemIds: [UUID]) throws -> [UUID: WatchProgress]
    /// Non-voided focus sessions of these items, oldest first.
    func focusSessions(itemIds: [UUID]) throws -> [FocusSession]
    /// Non-voided check-ins of any item with `from <= localDay <= through` (last week's card).
    func checkIns(from: LocalDay, through: LocalDay) throws -> [CheckIn]
    /// Non-voided focus sessions of any item with `from <= localDay <= through`.
    func focusSessions(from: LocalDay, through: LocalDay) throws -> [FocusSession]
    func focusSession(id: UUID) throws -> FocusSession?
    /// Every time block of `from` and later days, removed ones included (a hand tick a
    /// removed block used stays used), by start.
    func timeBlocks(from: LocalDay) throws -> [TimeBlock]
    /// Live blocks still waiting to decide, any day.
    func pendingTimeBlocks() throws -> [TimeBlock]
    func timeBlock(id: UUID) throws -> TimeBlock?
    /// Live (not deleted) steps of these tasks.
    func steps(taskIds: [UUID]) throws -> [Step]
    /// A step, deleted or not.
    func step(id: UUID) throws -> Step?
    /// Live (not voided) step ticks of these tasks, oldest first.
    func stepTicks(taskIds: [UUID]) throws -> [StepTick]
    /// Notes not deleted (SPEC "Notes"), oldest first.
    func quickNotes() throws -> [QuickNote]
    /// A note, deleted or not.
    func quickNote(id: UUID) throws -> QuickNote?
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
    public var watchProgress: [WatchProgress]
    public var focusSessions: [FocusSession]
    public var timeBlocks: [TimeBlock]
    public var steps: [Step]
    public var stepTicks: [StepTick]
    public var quickNotes: [QuickNote]

    public init(items: [Item], checkIns: [CheckIn], plans: [Plan], goalRounds: [GoalRound],
                reminders: [Reminder] = [], settings: [SettingRecord] = [], laterReviews: [LaterReview] = [],
                watchProgress: [WatchProgress] = [], focusSessions: [FocusSession] = [],
                timeBlocks: [TimeBlock] = [], steps: [Step] = [], stepTicks: [StepTick] = [],
                quickNotes: [QuickNote] = []) {
        self.items = items
        self.checkIns = checkIns
        self.plans = plans
        self.goalRounds = goalRounds
        self.reminders = reminders
        self.settings = settings
        self.laterReviews = laterReviews
        self.watchProgress = watchProgress
        self.focusSessions = focusSessions
        self.timeBlocks = timeBlocks
        self.steps = steps
        self.stepTicks = stepTicks
        self.quickNotes = quickNotes
    }

    private enum CodingKeys: String, CodingKey {
        case items, checkIns, plans, goalRounds, reminders, settings, laterReviews, watchProgress, focusSessions, timeBlocks, steps, stepTicks
        case quickNotes
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
            laterReviews: try c.decodeIfPresent([LaterReview].self, forKey: .laterReviews) ?? [],
            watchProgress: try c.decodeIfPresent([WatchProgress].self, forKey: .watchProgress) ?? [],
            focusSessions: try c.decodeIfPresent([FocusSession].self, forKey: .focusSessions) ?? [],
            timeBlocks: try c.decodeIfPresent([TimeBlock].self, forKey: .timeBlocks) ?? [],
            steps: try c.decodeIfPresent([Step].self, forKey: .steps) ?? [],
            stepTicks: try c.decodeIfPresent([StepTick].self, forKey: .stepTicks) ?? [],
            quickNotes: try c.decodeIfPresent([QuickNote].self, forKey: .quickNotes) ?? []
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
    /// Sets the plan's `voidedAt`. Voids are monotonic: voiding twice is an error.
    func voidPlan(id: UUID, at: Date) throws
    func insert(_ round: GoalRound) throws
    /// Inserts, or replaces the row with the same id.
    func save(_ reminder: Reminder) throws
    func saveSetting(_ key: String, json: String, updatedAt: Date) throws
    func insert(_ review: LaterReview) throws
    /// Sets the review's `voidedAt`. Voids are monotonic: voiding twice is an error.
    func voidLaterReview(id: UUID, at: Date) throws
    /// Inserts or replaces the item's row, unless the stored one was observed later.
    func save(_ progress: WatchProgress) throws
    func insert(_ session: FocusSession) throws
    /// Sets `voidedAt`. Voids are monotonic: voiding twice is an error.
    func voidFocusSession(id: UUID, at: Date) throws
    /// Inserts, or replaces the row with the same id.
    func save(_ block: TimeBlock) throws
    /// Inserts, or replaces the row with the same id (its task never changes).
    func save(_ step: Step) throws
    func insert(_ tick: StepTick) throws
    /// Sets `voidedAt`. Voids are monotonic: voiding twice is an error.
    func voidStepTick(id: UUID, at: Date) throws
    /// Inserts, or replaces the row with the same id (when and during what never change).
    func save(_ note: QuickNote) throws
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
