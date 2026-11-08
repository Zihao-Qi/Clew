import ClewCore
import ClewDomain
@testable import ClewStore
import Foundation
import GRDB
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000) // whole seconds survive the round trip

private func day(_ s: String) -> LocalDay { LocalDay(string: s)! }

private func sampleItem(_ kind: ItemKind = .goal, state: ItemState = .active) -> Item {
    Item(
        id: UUID(), kind: kind, title: "ML course", url: URL(string: "https://course.example/a?b=1"),
        note: "n", schedule: .weekdays([.monday, .friday]), progress: .counter(target: 30), state: state,
        plannedDay: day("2026-11-11"), sortKey: 2.5, source: .extensionYouTube, externalRef: "yt:\(UUID().uuidString)",
        createdAt: t0, updatedAt: t0.addingTimeInterval(60)
    )
}

private func sampleCheckIn(_ item: Item, _ d: String = "2026-11-11", amount: Int = 1) -> CheckIn {
    CheckIn(id: UUID(), itemId: item.id, localDay: day(d), at: t0, timeZoneId: "Europe/Paris",
            amount: amount, source: .user)
}

@Suite struct SQLiteStoreTests {
    @Test func itemsCheckInsAndPlansRoundTrip() throws {
        let store = try SQLiteStore.inMemory()
        let item = sampleItem()
        let c = sampleCheckIn(item, amount: 2)
        let p = Plan(id: UUID(), itemId: item.id, localDay: day("2026-11-11"), at: t0, source: .user)
        try store.write { w in
            try w.insert(item)
            try w.insert(c)
            try w.insert(p)
        }
        let (i2, c2, p2) = try store.read { r in
            (try r.item(id: item.id), try r.checkIn(id: c.id), try r.plans(itemId: item.id))
        }
        #expect(i2 == item)
        #expect(c2 == c)
        #expect(p2 == [p])
    }

    @Test func queriesFilterByStateDeletionDayAndVoid() throws {
        let store = try SQLiteStore.inMemory()
        let active = sampleItem(), later = sampleItem(.link, state: .later)
        var deleted = sampleItem()
        deleted.deletedAt = t0
        let old = sampleCheckIn(active, "2026-11-01", amount: 5)
        let recent = sampleCheckIn(active, "2026-11-10", amount: 2)
        let voided = sampleCheckIn(active, "2026-11-11", amount: 7)
        try store.write { w in
            for i in [active, later, deleted] { try w.insert(i) }
            for c in [old, recent, voided] { try w.insert(c) }
            try w.voidCheckIn(id: voided.id, at: t0, reason: "undo")
        }
        let r = (
            active: try store.read { try $0.items(inStates: [.active]).map(\.id) },
            later: try store.read { try $0.items(inStates: [.later]).map(\.id) },
            recent: try store.read { try $0.checkIns(itemIds: [active.id], from: day("2026-11-09")).map(\.id) },
            lifetime: try store.read { try $0.lifetimeAmounts(itemIds: [active.id, later.id]) },
            none: try store.read { try $0.checkIns(itemIds: [], from: day("2026-11-09")) },
            maxSort: try store.read { try $0.maxSortKey() }
        )
        #expect(r.active == [active.id])
        #expect(r.later == [later.id])
        #expect(r.recent == [recent.id])
        #expect(r.lifetime == [active.id: 7])
        #expect(r.none.isEmpty)
        #expect(r.maxSort == 2.5)
    }

    @Test func aThrowingWriteRollsBackEverything() throws {
        struct Boom: Error {}
        let store = try SQLiteStore.inMemory()
        let item = sampleItem()
        #expect(throws: Boom.self) {
            try store.write { w in
                try w.insert(item)
                throw Boom()
            }
        }
        #expect(try store.read { try $0.item(id: item.id) } == nil)
    }

    @Test func observersHearCommittedWrites() async throws {
        let store = try SQLiteStore.inMemory()
        let counter = Counter()
        let token = store.observeChanges { counter.increment() }
        try store.write { try $0.insert(sampleItem()) }
        #expect(counter.value == 1)
        token.cancel()
        try store.write { try $0.insert(sampleItem()) }
        #expect(counter.value == 1)
    }

    @Test func fileDatabaseSurvivesReopening() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clew.sqlite")
        let item = sampleItem()
        do {
            let store = try SQLiteStore.open(at: url)
            try store.write { try $0.insert(item) }
        }
        let reopened = try SQLiteStore.open(at: url)
        #expect(try reopened.read { try $0.item(id: item.id) } == item)
    }
}

/// AGENTS.md rule 6, enforced by the database rather than by convention.
@Suite struct FactImmutabilityTests {
    private func seeded() throws -> (SQLiteStore, CheckIn, Plan) {
        let store = try SQLiteStore.inMemory()
        let item = sampleItem()
        let c = sampleCheckIn(item)
        let p = Plan(id: UUID(), itemId: item.id, localDay: day("2026-11-11"), at: t0, source: .user)
        var other = sampleItem()
        other.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        try store.write { w in
            try w.insert(item)
            try w.insert(other)
            try w.insert(c)
            try w.insert(p)
        }
        return (store, c, p)
    }

    @Test(arguments: [
        "localDay = '2026-11-12'", "amount = 3", "at = '2030-01-01 00:00:00.000'",
        "timeZoneId = 'UTC'", "source = 'dayflow'", "itemId = '00000000-0000-0000-0000-0000000000AA'",
    ])
    func checkInSubstanceCannotChange(_ assignment: String) throws {
        let (store, c, _) = try seeded()
        #expect(throws: DatabaseError.self) {
            try store.writer.write { try $0.execute(sql: "UPDATE checkIn SET \(assignment) WHERE id = ?", arguments: [c.id.uuidString]) }
        }
        #expect(try store.read { try $0.checkIn(id: c.id) } == c)
    }

    @Test func ratingCanChangeAndSettingAFieldToItsOwnValueIsAllowed() throws {
        let (store, c, _) = try seeded()
        try store.writer.write { db in
            try db.execute(sql: "UPDATE checkIn SET rating = 2, ratedAt = ?, amount = amount WHERE id = ?",
                           arguments: [t0, c.id.uuidString])
        }
        #expect(try store.read { try $0.checkIn(id: c.id) }?.rating == 2)
    }

    @Test func itemsAreTombstonedNeverDeleted() throws {
        // An item with no facts, so a foreign key cannot be what stops the delete.
        let store = try SQLiteStore.inMemory()
        let item = sampleItem()
        try store.write { try $0.insert(item) }
        #expect(throws: DatabaseError.self) {
            try store.writer.write { try $0.execute(sql: "DELETE FROM item") }
        }
        #expect(try store.read { try $0.item(id: item.id) } == item)
    }

    @Test func factsCannotBeDeleted() throws {
        let (store, _, _) = try seeded()
        for table in ["checkIn", "plan"] {
            #expect(throws: DatabaseError.self) {
                try store.writer.write { try $0.execute(sql: "DELETE FROM \(table)") }
            }
        }
    }

    @Test func voidsAreMonotonic() throws {
        let (store, c, p) = try seeded()
        try store.write { try $0.voidCheckIn(id: c.id, at: t0, reason: "undo") }
        #expect(throws: DatabaseError.self) {
            try store.write { try $0.voidCheckIn(id: c.id, at: t0.addingTimeInterval(1), reason: "again") }
        }
        #expect(throws: DatabaseError.self) {
            try store.writer.write { try $0.execute(sql: "UPDATE checkIn SET voidedAt = NULL WHERE id = ?", arguments: [c.id.uuidString]) }
        }
        try store.writer.write { try $0.execute(sql: "UPDATE plan SET voidedAt = ? WHERE id = ?", arguments: [t0, p.id.uuidString]) }
        #expect(throws: DatabaseError.self) {
            try store.writer.write { try $0.execute(sql: "UPDATE plan SET voidedAt = NULL WHERE id = ?", arguments: [p.id.uuidString]) }
        }
        let stored = try store.read { try $0.checkIn(id: c.id) }
        #expect(stored?.voidReason == "undo")
    }

    @Test(arguments: ["localDay = '2026-11-12'", "itemId = '00000000-0000-0000-0000-0000000000AA'", "at = '2030-01-01 00:00:00.000'", "source = 'dayflow'"])
    func planSubstanceCannotChange(_ assignment: String) throws {
        let (store, _, p) = try seeded()
        #expect(throws: DatabaseError.self) {
            try store.writer.write { try $0.execute(sql: "UPDATE plan SET \(assignment) WHERE id = ?", arguments: [p.id.uuidString]) }
        }
    }
}

/// The command layer end to end on the real database.
@Suite struct CommandsOnSQLiteTests {
    struct Clock: ClewDomain.Clock { let date: Date; func now() -> Date { date } }
    struct Zone: TimeZoneSource { func current() -> TimeZone { TimeZone(identifier: "Europe/Paris")! } }

    @Test func dayInTheLife() throws {
        let store = try SQLiteStore.inMemory()
        let clew = Clew(store: store, clock: Clock(date: t0), zones: Zone())
        let goal = try clew.addItem(NewItem(title: "ML course", shape: .goal(target: 30, schedule: .daily)))
        let habit = try clew.addItem(NewItem(title: "Stretch", shape: .habit(.timesPerWeek(3))))
        let link = try clew.addItem(NewItem(title: "Talk", url: URL(string: "https://youtu.be/x"), shape: .later))
        try clew.checkIn(itemId: goal.id)
        try clew.checkIn(itemId: goal.id)
        try clew.checkIn(itemId: habit.id)
        try clew.undoToday(itemId: habit.id)
        try clew.planForToday(itemIds: [link.id])

        let today = try clew.today()
        #expect(today.rows.map(\.id) == [goal.id, habit.id, link.id])
        #expect(today.done == 1 && today.total == 3)
        #expect(today.rows[0].lifetimeAmount == 2)
        #expect(try clew.laterCount() == 0)
        #expect(try store.read { try $0.plans(itemId: link.id) }.count == 1)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
