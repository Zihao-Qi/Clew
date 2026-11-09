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
    /// Sum of non-voided check-in amounts per item, all time. Missing means 0.
    func lifetimeAmounts(itemIds: [UUID]) throws -> [UUID: Int]
    func plans(itemId: UUID) throws -> [Plan]
    func maxSortKey() throws -> Double?
}

public protocol StoreWriter: StoreReader {
    func insert(_ item: Item) throws
    /// Replaces the definition row with the same id.
    func update(_ item: Item) throws
    func insert(_ checkIn: CheckIn) throws
    /// Sets `voidedAt`/`voidReason`. Voids are monotonic: voiding twice is an error.
    func voidCheckIn(id: UUID, at: Date, reason: String) throws
    func insert(_ plan: Plan) throws
}
