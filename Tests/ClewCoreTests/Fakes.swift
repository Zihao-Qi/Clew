import ClewCore
import ClewDomain
import Foundation

final class TestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    func now() -> Date { lock.withLock { current } }
    func set(_ date: Date) { lock.withLock { current = date } }
}

struct FixedZone: TimeZoneSource {
    let zone: TimeZone
    init(_ identifier: String) { zone = TimeZone(identifier: identifier)! }
    func current() -> TimeZone { zone }
}

/// An in-memory `ClewStore` with real transaction semantics: a write works on a
/// copy, which is committed only if the body returns. It enforces the same fact
/// rules as the SQLite triggers.
final class FakeStore: ClewStore, @unchecked Sendable {
    struct State {
        var items: [UUID: Item] = [:]
        var checkIns: [UUID: CheckIn] = [:]
        var plans: [UUID: Plan] = [:]
        var rounds: [UUID: GoalRound] = [:]
        var reminders: [UUID: Reminder] = [:]
        var settings: [String: SettingRecord] = [:]
        var laterReviews: [UUID: LaterReview] = [:]
    }

    enum FactViolation: Error { case revoid, duplicate, missingItem }

    private let lock = NSRecursiveLock()
    private(set) var state = State()
    private var observers: [UUID: @Sendable () -> Void] = [:]

    func read<T>(_ body: (any StoreReader) throws -> T) throws -> T {
        try lock.withLock { try body(Access(state: state)) }
    }

    func write<T>(_ body: (any StoreWriter) throws -> T) throws -> T {
        let (result, callbacks) = try lock.withLock {
            let access = Access(state: state)
            let result = try body(access)
            state = access.state
            return (result, Array(observers.values))
        }
        callbacks.forEach { $0() }
        return result
    }

    func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> any StoreObservation {
        let id = UUID()
        lock.withLock { observers[id] = onChange }
        return Token { [weak self] in self?.lock.withLock { _ = self?.observers.removeValue(forKey: id) } }
    }

    final class Token: StoreObservation, @unchecked Sendable {
        let onCancel: () -> Void
        init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        func cancel() { onCancel() }
    }

    final class Access: StoreWriter {
        var state: State
        init(state: State) { self.state = state }

        func item(id: UUID) throws -> Item? { state.items[id] }
        func items(inStates states: Set<ItemState>) throws -> [Item] {
            state.items.values.filter { $0.deletedAt == nil && states.contains($0.state) }
        }
        func checkIn(id: UUID) throws -> CheckIn? { state.checkIns[id] }
        func checkIns(itemIds: [UUID], from: LocalDay) throws -> [CheckIn] {
            let ids = Set(itemIds)
            return state.checkIns.values
                .filter { ids.contains($0.itemId) && $0.localDay >= from && !$0.isVoided }
                .sorted { $0.at < $1.at }
        }
        func roundStarts(itemIds: [UUID]) throws -> [UUID: Date] {
            let ids = Set(itemIds)
            var result: [UUID: Date] = [:]
            for r in state.rounds.values where ids.contains(r.itemId) && r.voidedAt == nil {
                result[r.itemId] = max(result[r.itemId] ?? r.startedAt, r.startedAt)
            }
            return result
        }
        func progressAmounts(itemIds: [UUID]) throws -> [UUID: Int] {
            let starts = try roundStarts(itemIds: itemIds)
            let ids = Set(itemIds)
            var result: [UUID: Int] = [:]
            for c in state.checkIns.values where ids.contains(c.itemId) && !c.isVoided {
                if let start = starts[c.itemId], c.at < start { continue }
                result[c.itemId, default: 0] += c.amount
            }
            return result
        }
        func goalRounds(itemId: UUID) throws -> [GoalRound] {
            state.rounds.values.filter { $0.itemId == itemId }.sorted { $0.startedAt < $1.startedAt }
        }
        func insert(_ round: GoalRound) throws {
            guard state.rounds[round.id] == nil else { throw FactViolation.duplicate }
            guard state.items[round.itemId] != nil else { throw FactViolation.missingItem }
            state.rounds[round.id] = round
        }
        func plans(itemId: UUID) throws -> [Plan] {
            state.plans.values.filter { $0.itemId == itemId }.sorted { $0.at < $1.at }
        }
        func maxSortKey() throws -> Double? { state.items.values.map(\.sortKey).max() }
        func activeDays(from: LocalDay) throws -> Set<LocalDay> {
            Set(state.checkIns.values.filter { !$0.isVoided && $0.localDay >= from }.map(\.localDay))
        }
        func allRecords() throws -> ExportRecords {
            ExportRecords(
                items: state.items.values.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) },
                checkIns: state.checkIns.values.sorted { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) },
                plans: state.plans.values.sorted { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) },
                goalRounds: state.rounds.values.sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) },
                reminders: state.reminders.values.sorted { ($0.updatedAt, $0.id.uuidString) < ($1.updatedAt, $1.id.uuidString) },
                settings: state.settings.values.sorted { $0.key < $1.key },
                laterReviews: state.laterReviews.values.sorted { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }
            )
        }
        func reminders() throws -> [Reminder] {
            state.reminders.values.filter { $0.deletedAt == nil }.sorted { $0.itemId.uuidString < $1.itemId.uuidString }
        }
        func setting(_ key: String) throws -> String? { state.settings[key]?.value }
        func laterReviews(itemIds: [UUID]) throws -> [LaterReview] {
            let ids = Set(itemIds)
            return state.laterReviews.values.filter { ids.contains($0.itemId) && $0.voidedAt == nil }.sorted { $0.at < $1.at }
        }
        func letGoCount() throws -> Int {
            state.laterReviews.values.filter { $0.decision == .letGo && $0.voidedAt == nil }.count
        }
        func insert(_ review: LaterReview) throws {
            guard state.laterReviews[review.id] == nil else { throw FactViolation.duplicate }
            guard state.items[review.itemId] != nil else { throw FactViolation.missingItem }
            state.laterReviews[review.id] = review
        }
        func save(_ reminder: Reminder) throws {
            guard state.items[reminder.itemId] != nil else { throw FactViolation.missingItem }
            if reminder.deletedAt == nil,
               state.reminders.values.contains(where: { $0.itemId == reminder.itemId && $0.deletedAt == nil && $0.id != reminder.id }) {
                throw FactViolation.duplicate
            }
            state.reminders[reminder.id] = reminder
        }
        func saveSetting(_ key: String, json: String, updatedAt: Date) throws {
            state.settings[key] = SettingRecord(key: key, value: json, updatedAt: updatedAt)
        }

        func insert(_ item: Item) throws {
            guard state.items[item.id] == nil else { throw FactViolation.duplicate }
            state.items[item.id] = item
        }
        func update(_ item: Item) throws {
            guard state.items[item.id] != nil else { throw FactViolation.missingItem }
            state.items[item.id] = item
        }
        func insert(_ checkIn: CheckIn) throws {
            guard state.checkIns[checkIn.id] == nil else { throw FactViolation.duplicate }
            guard state.items[checkIn.itemId] != nil else { throw FactViolation.missingItem }
            state.checkIns[checkIn.id] = checkIn
        }
        func voidCheckIn(id: UUID, at: Date, reason: String) throws {
            guard var c = state.checkIns[id] else { return }
            guard c.voidedAt == nil else { throw FactViolation.revoid }
            c.voidedAt = at
            c.voidReason = reason
            state.checkIns[id] = c
        }
        func insert(_ plan: Plan) throws {
            guard state.plans[plan.id] == nil else { throw FactViolation.duplicate }
            state.plans[plan.id] = plan
        }
    }
}
