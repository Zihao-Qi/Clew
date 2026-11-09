import ClewDomain
import Foundation
import Testing

@Suite struct InstantTests {
    private let ny = TimeZone(identifier: "America/New_York")!
    private func t(_ h: Int, _ m: Int = 0) -> TimeOfDay { TimeOfDay(hour: h, minute: m)! }

    @Test func aTimeAfterRolloverIsOnTheSameDate() {
        #expect(day("2026-11-09").instant(at: t(9), in: ny, rolloverHour: 4) == instant(2026, 11, 9, 9, zone: "America/New_York"))
        #expect(day("2026-11-09").instant(at: t(4), in: ny, rolloverHour: 4) == instant(2026, 11, 9, 4, zone: "America/New_York"))
    }

    /// ARCHITECTURE §4.3: a 01:00 reminder on Monday's item fires at Tuesday 01:00.
    @Test func aTimeBeforeRolloverBelongsToTheNextCalendarDate() {
        #expect(day("2026-11-09").instant(at: t(1), in: ny, rolloverHour: 4) == instant(2026, 11, 10, 1, zone: "America/New_York"))
        #expect(day("2026-11-09").instant(at: t(3, 59), in: ny, rolloverHour: 4) == instant(2026, 11, 10, 3, 59, zone: "America/New_York"))
    }

    @Test func dstDaysUseTheWallClock() {
        // Spring forward Mar 8: 09:00 EDT is 13:00 UTC; 02:30 does not exist → 03:30 EDT.
        #expect(day("2026-03-08").instant(at: t(9), in: ny, rolloverHour: 0) == utc(2026, 3, 8, 13))
        #expect(day("2026-03-08").instant(at: t(2, 30), in: ny, rolloverHour: 0) == utc(2026, 3, 8, 7, 30))
        // Fall back Nov 1: 21:00 EST is Nov 2 02:00 UTC.
        #expect(day("2026-11-01").instant(at: t(21), in: ny, rolloverHour: 4) == utc(2026, 11, 2, 2))
    }

    @Test func timeOfDayRejectsNonsense() {
        #expect(TimeOfDay(hour: 24, minute: 0) == nil)
        #expect(TimeOfDay(hour: 9, minute: 60) == nil)
        #expect(TimeOfDay(hour: -1, minute: 0) == nil)
        #expect(TimeOfDay(hour: 23, minute: 59) != nil)
    }
}
