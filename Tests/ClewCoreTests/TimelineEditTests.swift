import ClewCore
import ClewDomain
import Foundation
import Testing

/// Edit's "On today's timeline" (SPEC 2026-11-18).
@Suite struct TimelineEditTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func block(_ start: Date, _ minutes: Int) -> TimeBlock {
        TimeBlock(id: UUID(), itemId: UUID(), localDay: LocalDay(year: 2026, month: 11, day: 18)!, start: start,
                  minutes: minutes, placedAt: t0, updatedAt: t0)
    }

    @Test func saveDoesOnlyWhatChanged() {
        let open = block(t0, 30)
        #expect(TimelineEdit(open: nil, wanted: nil) == .keep)
        #expect(TimelineEdit(open: open, wanted: (t0, 30)) == .keep)                      // untouched
        #expect(TimelineEdit(open: open, wanted: nil) == .remove(open.id))                 // unchecked
        #expect(TimelineEdit(open: nil, wanted: (t0, 30)) == .place(start: t0, minutes: 30)) // checked
        let later = t0.addingTimeInterval(900)
        #expect(TimelineEdit(open: open, wanted: (later, 30)) == .place(start: later, minutes: 30))
        #expect(TimelineEdit(open: open, wanted: (t0, 45)) == .place(start: t0, minutes: 45))
    }

    @Test func theOpenBlockIsTodaysBlockNotEnded() throws {
        func at(_ h: Int) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "America/New_York")!
            return cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: h))!
        }
        let store = FakeStore()
        let clock = TestClock(at(9))
        let clew = Clew(store: store, clock: clock, zones: FixedZone("America/New_York"))
        let item = try clew.addItem(NewItem(title: "a", shape: .today))
        #expect(try clew.openBlock(itemId: item.id) == nil)
        let block = try clew.placeOnTimeline(itemId: item.id, start: at(11), minutes: 30)
        #expect(try clew.openBlock(itemId: item.id)?.id == block.id)
        clock.set(at(12))                                                   // it has ended
        #expect(try clew.openBlock(itemId: item.id) == nil)
    }
}
