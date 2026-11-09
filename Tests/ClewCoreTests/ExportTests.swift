import ClewCore
import ClewDomain
import Foundation
import Testing

private func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
}

@Suite struct ActiveDaysTests {
    @Test func countsDistinctTickedDaysInTheLast7And14() throws {
        let store = FakeStore()
        let clock = TestClock(local(2026, 11, 1, 10))
        let clew = Clew(store: store, clock: clock, zones: FixedZone("America/New_York"))
        let habit = try clew.addItem(NewItem(title: "h", shape: .habit(.daily)))
        let goal = try clew.addItem(NewItem(title: "g", shape: .goal(target: 99, schedule: .daily)))
        // The 14 days ending Nov 16 start Nov 3; the 7 days start Nov 10.
        // Nov 2 (outside), Nov 3 (first of 14), Nov 9 (outside 7), Nov 10 (first of 7),
        // Nov 16 twice (one day), Nov 15 voided only (not active), Nov 17 (a future day,
        // e.g. after flying west; not counted).
        for (d, h) in [(2, 10), (3, 10), (9, 10), (10, 10), (16, 9), (17, 10)] {
            clock.set(local(2026, 11, d, h))
            try clew.checkIn(itemId: habit.id)
        }
        clock.set(local(2026, 11, 16, 11))
        try clew.checkIn(itemId: goal.id)
        clock.set(local(2026, 11, 15, 10))
        let voided = try clew.checkIn(itemId: habit.id)
        try clew.voidCheckIn(id: voided.id, reason: "undo")
        clock.set(local(2026, 11, 16, 20))
        #expect(try clew.activeDays() == ActiveDays(last7: 2, last14: 4))
    }
}

@Suite struct ExportDocumentTests {
    @Test func exportIncludesDeletedItemsAndVoidedFacts() throws {
        let store = FakeStore()
        let clock = TestClock(local(2026, 11, 11, 10))
        let clew = Clew(store: store, clock: clock, zones: FixedZone("America/New_York"))
        let gone = try clew.addItem(NewItem(title: "gone", shape: .habit(.daily)))
        let c = try clew.checkIn(itemId: gone.id)
        try clew.undoToday(itemId: gone.id)
        try clew.deleteItem(itemId: gone.id)
        let doc = try clew.exportDocument()
        #expect(doc.clewExportVersion == 1)
        #expect(doc.exportedAt == local(2026, 11, 11, 10))
        #expect(doc.records.items.map(\.id) == [gone.id])
        #expect(doc.records.items.first?.deletedAt != nil)
        #expect(doc.records.checkIns.map(\.id) == [c.id])
        #expect(doc.records.checkIns.first?.voidedAt != nil)
    }

    @Test func otherVersionsAreRejected() throws {
        let doc = ExportDocument(exportedAt: Date(timeIntervalSince1970: 0),
                                 records: ExportRecords(items: [], checkIns: [], plans: [], goalRounds: []))
        let json = String(decoding: try doc.encoded(), as: UTF8.self)
            .replacingOccurrences(of: "\"clewExportVersion\" : 1", with: "\"clewExportVersion\" : 2")
        #expect(throws: DecodingError.self) { try ExportDocument.decode(Data(json.utf8)) }
        #expect(try ExportDocument.decode(try doc.encoded()) == doc)
    }
}
