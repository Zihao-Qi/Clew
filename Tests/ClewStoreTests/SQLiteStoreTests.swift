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
            lifetime: try store.read { try $0.progressAmounts(itemIds: [active.id, later.id]) },
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
        let goal = sampleItem()
        try store.write { try $0.insert(goal) }
        #expect(counter.value == 1)
        try store.write {
            try $0.insert(GoalRound(id: UUID(), itemId: goal.id, startedAt: t0, localDay: day("2026-11-11"),
                                    target: 30, source: .user))
        }
        #expect(counter.value == 2)
        token.cancel()
        try store.write { try $0.insert(sampleItem()) }
        #expect(counter.value == 2)
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

    @Test func ratingGoesThroughTheTriggersAndKeepsTheRestOfTheFact() throws {
        let (store, c, _) = try seeded()
        try store.write { try $0.rateCheckIn(id: c.id, rating: 3, at: t0.addingTimeInterval(5)) }
        let rated = try #require(try store.read { try $0.checkIn(id: c.id) })
        #expect(rated.rating == 3 && rated.ratedAt == t0.addingTimeInterval(5))
        #expect(rated.amount == c.amount && rated.localDay == c.localDay && rated.at == c.at)
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

@Suite struct GoalRoundStoreTests {
    @Test func progressCountsFromTheLatestLiveRound() throws {
        let store = try SQLiteStore.inMemory()
        let goal = sampleItem()
        let early = sampleCheckIn(goal, amount: 5) // at t0
        let late = CheckIn(id: UUID(), itemId: goal.id, localDay: day("2026-11-11"), at: t0.addingTimeInterval(7200),
                           timeZoneId: "UTC", amount: 2, source: .user)
        let r1 = GoalRound(id: UUID(), itemId: goal.id, startedAt: t0.addingTimeInterval(3600),
                           localDay: day("2026-11-11"), target: 30, source: .user)
        let r2 = GoalRound(id: UUID(), itemId: goal.id, startedAt: t0.addingTimeInterval(10_800),
                           localDay: day("2026-11-11"), target: 30, source: .user)
        try store.write { w in
            try w.insert(goal)
            try w.insert(early)
            try w.insert(late)
            try w.insert(r1)
        }
        #expect(try store.read { try $0.progressAmounts(itemIds: [goal.id]) } == [goal.id: 2])
        #expect(try store.read { try $0.roundStarts(itemIds: [goal.id]) } == [goal.id: r1.startedAt])
        try store.write { try $0.insert(r2) }
        #expect(try store.read { try $0.progressAmounts(itemIds: [goal.id]) }[goal.id] == nil)
        // A voided round no longer counts: back to r1.
        try store.writer.write { try $0.execute(sql: "UPDATE goalRound SET voidedAt = ? WHERE id = ?", arguments: [t0, r2.id.uuidString]) }
        #expect(try store.read { try $0.progressAmounts(itemIds: [goal.id]) } == [goal.id: 2])
        #expect(try store.read { try $0.roundStarts(itemIds: [goal.id]) } == [goal.id: r1.startedAt])
        #expect(try store.read { try $0.goalRounds(itemId: goal.id) }.map(\.id) == [r1.id, r2.id])
    }

    @Test(arguments: [
        "target = 99", "startedAt = '2030-01-01 00:00:00.000'", "source = 'dayflow'", "localDay = '2026-11-12'",
        // A real second item and a fresh id, so no foreign key or uniqueness rule can be what stops it.
        "itemId = '00000000-0000-0000-0000-0000000000BB'", "id = '00000000-0000-0000-0000-0000000000CC'",
    ])
    func goalRoundsAreFacts(_ assignment: String) throws {
        let store = try SQLiteStore.inMemory()
        let goal = sampleItem()
        var other = sampleItem()
        other.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let round = GoalRound(id: UUID(), itemId: goal.id, startedAt: t0, localDay: day("2026-11-11"), target: 30, source: .user)
        try store.write { w in
            try w.insert(goal)
            try w.insert(other)
            try w.insert(round)
        }
        #expect(throws: DatabaseError.self) {
            try store.writer.write { try $0.execute(sql: "UPDATE goalRound SET \(assignment)") }
        }
        #expect(throws: DatabaseError.self) {
            try store.writer.write { try $0.execute(sql: "DELETE FROM goalRound") }
        }
        try store.writer.write { try $0.execute(sql: "UPDATE goalRound SET voidedAt = ?", arguments: [t0]) }
        #expect(throws: DatabaseError.self) {
            try store.writer.write { try $0.execute(sql: "UPDATE goalRound SET voidedAt = NULL") }
        }
    }

    @Test func titleOriginRoundTripsAndDefaultsToTypedForOldRows() throws {
        // A database created by v1a, before titleOrigin existed.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v1")
        let oldId = UUID()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO item (id, kind, title, schedule, progress, state, sortKey, source, createdAt, updatedAt)
                VALUES (?, 'once', 'Old', '{"type":"unscheduled","v":1}', '{"type":"none","v":1}', 'later', 1,
                        'user', ?, ?)
                """, arguments: [oldId.uuidString, t0, t0])
        }
        let store = try SQLiteStore(writer: queue)
        #expect(try store.read { try $0.item(id: oldId) }?.titleOrigin == .typed)
        var fetched = sampleItem()
        fetched.titleOrigin = .fetched
        try store.write { try $0.insert(fetched) }
        #expect(try store.read { try $0.item(id: fetched.id) }?.titleOrigin == .fetched)
    }
}

@Suite struct ExportOnSQLiteTests {
    struct Clock: ClewDomain.Clock { let date: Date; func now() -> Date { date } }
    struct Zone: TimeZoneSource { func current() -> TimeZone { TimeZone(identifier: "Asia/Tokyo")! } }

    /// ARCHITECTURE §7: a complete and lossless round trip of definitions and facts.
    @Test func exportRoundTripsEveryRowLosslessly() throws {
        let store = try SQLiteStore.inMemory()
        let clew = Clew(store: store, clock: Clock(date: t0.addingTimeInterval(0.123)), zones: Zone())
        let goal = try clew.addItem(NewItem(title: "Goal \"quoted\" / ünïcode", titleOrigin: .fetched,
                                            url: URL(string: "https://example.com/a?b=1&c=2"),
                                            shape: .goal(target: 2, schedule: .weekdays([.monday, .sunday]))))
        let later = try clew.addItem(NewItem(title: "Later", shape: .later))
        let habit = try clew.addItem(NewItem(title: "Habit", shape: .habit(.timesPerWeek(3))))
        try clew.checkIn(itemId: goal.id)
        try clew.checkIn(itemId: goal.id)
        try clew.startNextRound(itemId: goal.id)
        try clew.planForToday(itemIds: [later.id])
        try clew.checkIn(itemId: habit.id)
        try clew.undoToday(itemId: habit.id)
        try clew.deleteItem(itemId: habit.id)

        let stored = try store.read { try $0.allRecords() }
        #expect(stored.items.count == 3 && stored.checkIns.count == 3 && stored.plans.count == 1 && stored.goalRounds.count == 1)
        let doc = try clew.exportDocument()
        let data = try doc.encoded()
        let back = try ExportDocument.decode(data)
        // Lossless at the database's precision (milliseconds): the export is exactly the
        // stored rows, and decoding it loses nothing the export wrote.
        #expect(try ExportDocument(exportedAt: doc.exportedAt, records: stored).encoded() == data)
        #expect(try back.encoded() == data)
        #expect(back.records.items.map(\.id) == stored.items.map(\.id))
        let voidedBack: [Bool] = back.records.checkIns.map { $0.voidedAt != nil }
        let voidedStored: [Bool] = stored.checkIns.map { $0.voidedAt != nil }
        #expect(voidedBack == voidedStored && voidedStored.contains(true))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""titleOrigin" : "fetched""#))
        #expect(text.contains(#""deletedAt" : "2027-01-15T08:00:00.123Z""#))
        #expect(text.contains(#""clewExportVersion" : 1"#))
        #expect(text.contains(#""exportedAt" : "2027-01-15T08:00:00.123Z""#))
    }

    @Test func activeDaysIgnoreVoidedCheckIns() throws {
        let store = try SQLiteStore.inMemory()
        let item = sampleItem()
        let kept = sampleCheckIn(item, "2026-11-10")
        let voided = sampleCheckIn(item, "2026-11-11")
        let old = sampleCheckIn(item, "2026-11-01")
        try store.write { w in
            try w.insert(item)
            for c in [kept, voided, old] { try w.insert(c) }
            try w.voidCheckIn(id: voided.id, at: t0, reason: "undo")
        }
        #expect(try store.read { try $0.activeDays(from: day("2026-11-02")) } == [day("2026-11-10")])
    }
}

@Suite struct ReminderStoreTests {
    private func reminder(_ item: Item, id: UUID = UUID(), deleted: Bool = false) -> Reminder {
        Reminder(id: id, itemId: item.id, time: TimeOfDay(hour: 18, minute: 30)!, updatedAt: t0, deletedAt: deleted ? t0 : nil)
    }

    @Test func oneLiveReminderPerItem_tombstonesDoNotCount() throws {
        let store = try SQLiteStore.inMemory()
        let item = sampleItem()
        let first = reminder(item)
        try store.write { w in
            try w.insert(item)
            try w.save(first)
        }
        #expect(throws: DatabaseError.self) { try store.write { try $0.save(reminder(item)) } }
        var gone = first
        gone.deletedAt = t0
        try store.write { try $0.save(gone) } // update by id
        let second = reminder(item)
        try store.write { try $0.save(second) }
        #expect(try store.read { try $0.reminders() } == [second])
        #expect(throws: DatabaseError.self) { try store.writer.write { try $0.execute(sql: "DELETE FROM reminder") } }
        #expect(try store.read { try $0.allRecords() }.reminders.count == 2)
    }

    @Test func settingsUpsertByKey() throws {
        let store = try SQLiteStore.inMemory()
        #expect(try store.read { try $0.setting("summaries") } == nil)
        try store.write { try $0.saveSetting("summaries", json: #"{"a":1}"#, updatedAt: t0) }
        try store.write { try $0.saveSetting("summaries", json: #"{"a":2}"#, updatedAt: t0.addingTimeInterval(1)) }
        #expect(try store.read { try $0.setting("summaries") } == #"{"a":2}"#)
        #expect(try store.read { try $0.allRecords() }.settings == [SettingRecord(key: "summaries", value: #"{"a":2}"#, updatedAt: t0.addingTimeInterval(1))])
    }

    @Test func exportCarriesRemindersAndSettings_andOldExportsStillDecode() throws {
        let store = try SQLiteStore.inMemory()
        let item = sampleItem()
        try store.write { w in
            try w.insert(item)
            try w.save(reminder(item))
            try w.saveSetting("summaries", json: "{}", updatedAt: t0)
        }
        let data = try ExportDocument(exportedAt: t0, records: try store.read { try $0.allRecords() }).encoded()
        let back = try ExportDocument.decode(data)
        #expect(back.records.reminders.count == 1 && back.records.settings.count == 1)
        #expect(try back.encoded() == data)
        // A v1b-1 export has no reminders or settings keys.
        let old = #"{"clewExportVersion":1,"exportedAt":"2027-01-15T08:00:00.000Z","records":{"items":[],"checkIns":[],"plans":[],"goalRounds":[]}}"#
        #expect(try ExportDocument.decode(Data(old.utf8)).records.reminders.isEmpty)
    }
}

@Suite struct LaterReviewStoreTests {
    private func review(_ item: Item, _ decision: LaterReview.Decision) -> LaterReview {
        LaterReview(id: UUID(), itemId: item.id, decision: decision, at: t0, localDay: day("2026-11-09"), source: .user)
    }

    @Test func reviewsAreFactsAndOnlyLiveLetGosCount() throws {
        let store = try SQLiteStore.inMemory()
        let a = sampleItem(.link, state: .later), b = sampleItem(.link, state: .later)
        let gone = review(a, .letGo), kept = review(b, .keep), voided = review(b, .letGo)
        try store.write { w in
            try w.insert(a)
            try w.insert(b)
            for r in [gone, kept, voided] { try w.insert(r) }
        }
        try store.writer.write { try $0.execute(sql: "UPDATE laterReview SET voidedAt = ? WHERE id = ?", arguments: [t0, voided.id.uuidString]) }
        #expect(try store.read { try $0.letGoCount() } == 1)
        #expect(try store.read { try $0.laterReviews(itemIds: [b.id]) }.map(\.id) == [kept.id])
        for assignment in ["decision = 'keep'", "at = '2030-01-01 00:00:00.000'", "localDay = '2026-11-10'", "source = 'dayflow'"] {
            #expect(throws: DatabaseError.self) {
                try store.writer.write { try $0.execute(sql: "UPDATE laterReview SET \(assignment) WHERE id = ?", arguments: [gone.id.uuidString]) }
            }
        }
        #expect(throws: DatabaseError.self) { try store.writer.write { try $0.execute(sql: "DELETE FROM laterReview") } }
        #expect(throws: DatabaseError.self) {
            try store.writer.write { try $0.execute(sql: "UPDATE laterReview SET voidedAt = NULL WHERE id = ?", arguments: [voided.id.uuidString]) }
        }
        #expect(try store.read { try $0.allRecords() }.laterReviews.count == 3)
    }
}

@Suite struct FivePointMigrationTests {
    /// A v4 database with 3-point ratings, migrated to v5.
    @Test func ratingsMapAndTheFactRulesSurviveTheRebuild() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v4-later-reviews")
        let item = sampleItem()
        let ids = (0..<5).map { _ in UUID() }
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO item (id, kind, title, schedule, progress, state, sortKey, source, createdAt, updatedAt)
                VALUES (?, 'habit', 't', '{"type":"daily","v":1}', '{"type":"none","v":1}', 'active', 1, 'user', ?, ?)
                """, arguments: [item.id.uuidString, t0, t0])
            for (i, rating) in [1, 2, 3, nil, 2].enumerated() {
                try db.execute(sql: """
                    INSERT INTO checkIn (id, itemId, localDay, at, timeZoneId, amount, rating, ratedAt, source, voidedAt)
                    VALUES (?, ?, '2026-11-0\(i + 1)', ?, 'UTC', 1, ?, ?, 'user', ?)
                    """, arguments: [ids[i].uuidString, item.id.uuidString, t0, rating, rating == nil ? nil : t0,
                                     i == 4 ? t0 : nil])
            }
        }
        let store = try SQLiteStore(writer: queue)                     // runs v5
        let ratings = try ids.map { id in try store.read { try $0.checkIn(id: id) }?.rating }
        #expect(ratings == [2, 3, 5, nil, 3])                            // meh, okay, great; voided kept
        #expect(try store.read { try $0.checkIn(id: ids[4]) }?.voidedAt != nil)
        // The rebuilt table still enforces the fact rules and the new range.
        try store.write { try $0.rateCheckIn(id: ids[3], rating: 5, at: t0) }
        #expect(throws: DatabaseError.self) { try store.write { try $0.rateCheckIn(id: ids[3], rating: 6, at: t0) } }
        #expect(throws: DatabaseError.self) {
            try store.writer.write { try $0.execute(sql: "UPDATE checkIn SET amount = 9 WHERE id = ?", arguments: [ids[0].uuidString]) }
        }
        #expect(throws: DatabaseError.self) { try store.writer.write { try $0.execute(sql: "DELETE FROM checkIn") } }
        #expect(throws: DatabaseError.self) {
            try store.writer.write { try $0.execute(sql: "UPDATE checkIn SET voidedAt = NULL WHERE id = ?", arguments: [ids[4].uuidString]) }
        }
        #expect(try store.read { try $0.checkIns(itemIds: [item.id], from: day("2026-11-01")) }.count == 4)
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
        #expect(today.rows[0].progressAmount == 2)
        #expect(try clew.laterCount() == 0)
        #expect(try store.read { try $0.plans(itemId: link.id) }.count == 1)

        // Delete is a tombstone on the real database too: the row and its facts remain.
        try clew.deleteItem(itemId: goal.id)
        #expect(try clew.today().rows.map(\.id) == [habit.id, link.id])
        #expect(try store.read { try $0.item(id: goal.id) }?.deletedAt == t0)
        #expect(try store.read { try $0.checkIns(itemIds: [goal.id], from: day("2000-01-01")) }.count == 2)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
