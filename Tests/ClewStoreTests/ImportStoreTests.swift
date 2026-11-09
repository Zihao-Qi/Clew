import ClewCore
import ClewDomain
@testable import ClewStore
import Foundation
import Testing

final class StepClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    // Sub-millisecond on purpose: SQLite keeps milliseconds, so the restore rule must
    // compare dates that both went through the database.
    private var current = Date(timeIntervalSince1970: 1_800_000_000.123456)
    func now() -> Date { lock.withLock { current } }
    func advance() { lock.withLock { current += 3600.000_789 } }
}

struct ParisZone: TimeZoneSource { func current() -> TimeZone { TimeZone(identifier: "Europe/Paris")! } }

@Suite struct ImportStoreTests {
    let store: SQLiteStore
    let clock = StepClock()
    let clew: Clew
    init() throws {
        store = try SQLiteStore.inMemory()
        clew = Clew(store: store, clock: clock, zones: ParisZone())
    }
    private func batch(_ refs: [String]) -> ImportBatch {
        ImportBatch(source: .extensionYouTube, entries: refs.map { ExternalEntry(externalRef: $0, title: "v \($0)") },
                    listTotal: refs.count)
    }

    @Test func leaveAndComeBackRoundTripsThroughSQLite() throws {
        try clew.importExternal(batch(["aaaaaaaaaaa", "bbbbbbbbbbb"]))
        clock.advance()
        #expect(try clew.importExternal(batch(["aaaaaaaaaaa"])).letGo == 1)
        clock.advance()
        let back = try clew.importExternal(batch(["aaaaaaaaaaa", "bbbbbbbbbbb"]))
        #expect(back.restored == 1 && back.added == 0)
        #expect(try clew.laterCount() == 2)
        // The let-go was voided through the monotonic-void trigger.
        let reviews = try store.read { try $0.allRecords() }.laterReviews
        #expect(reviews.count == 1 && reviews[0].voidedAt != nil)
        #expect(throws: (any Error).self) {
            try store.write { try $0.voidLaterReview(id: reviews[0].id, at: Date()) }
        }
    }

    @Test func itemsBySourceIncludeDeletedOnes() throws {
        try clew.importExternal(batch(["aaaaaaaaaaa", "bbbbbbbbbbb"]))
        let user = try clew.addItem(NewItem(title: "mine", shape: .later))
        try clew.importExternal(batch(["aaaaaaaaaaa"]))
        let items = try store.read { try $0.items(source: .extensionYouTube) }
        #expect(Set(items.compactMap(\.externalRef)) == ["aaaaaaaaaaa", "bbbbbbbbbbb"])
        #expect(items.contains { $0.deletedAt != nil })
        #expect(!items.contains { $0.id == user.id })
    }

    @Test func onlyTheUsersLetGosAreCounted() throws {
        try clew.importExternal(batch(["aaaaaaaaaaa", "bbbbbbbbbbb"]))
        try clew.importExternal(batch(["aaaaaaaaaaa"]))                 // import lets b go
        let a = try #require(try clew.laterItems().first)
        try clew.letGo(itemId: a.id)                                    // the user lets a go
        #expect(try clew.lettingGoCount() == 1)
    }
}
