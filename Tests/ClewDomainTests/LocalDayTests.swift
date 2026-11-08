import ClewDomain
import Foundation
import Testing

/// Builds an instant from a wall-clock time in a zone, independently of LocalDay.
func instant(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, zone: String) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: zone)!
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

/// Builds an instant from a UTC time: unambiguous on DST days.
func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
    instant(y, m, d, h, min, zone: "UTC")
}

func day(_ s: String) -> LocalDay { LocalDay(string: s)! }

let newYork = TimeZone(identifier: "America/New_York")!

@Suite struct LocalDayTests {
    @Test func tickBeforeRolloverCountsForPreviousDay() {
        let at = instant(2026, 11, 10, 1, 30, zone: "Europe/London")
        #expect(LocalDay(of: at, in: TimeZone(identifier: "Europe/London")!, rolloverHour: 4) == day("2026-11-09"))
    }

    @Test func rolloverHourItselfStartsTheNewDay() {
        let zone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(LocalDay(of: instant(2026, 11, 10, 4, 0, zone: "Asia/Tokyo"), in: zone, rolloverHour: 4) == day("2026-11-10"))
        #expect(LocalDay(of: instant(2026, 11, 10, 3, 59, zone: "Asia/Tokyo"), in: zone, rolloverHour: 4) == day("2026-11-09"))
    }

    @Test func dayIsTakenInTheGivenZoneNotUTC() {
        // 02:00 UTC on Nov 10 is 21:00 on Nov 9 in New York.
        #expect(LocalDay(of: utc(2026, 11, 10, 2), in: newYork, rolloverHour: 4) == day("2026-11-09"))
        // and 11:00 on Nov 10 in Tokyo.
        #expect(LocalDay(of: utc(2026, 11, 10, 2), in: TimeZone(identifier: "Asia/Tokyo")!, rolloverHour: 4) == day("2026-11-10"))
    }

    /// Spring forward, New York, 2026-03-08: 02:00 → 03:00. At 04:30 EDT (08:30 UTC)
    /// only 3.5 hours have passed since midnight. "instant − 4h" would give Mar 7.
    @Test func springForwardDayUsesWallClock() {
        #expect(LocalDay(of: utc(2026, 3, 8, 8, 30), in: newYork, rolloverHour: 4) == day("2026-03-08"))
    }

    /// Fall back, New York, 2026-11-01: 02:00 → 01:00. At 03:30 EST (08:30 UTC) the
    /// wall clock is before 04:00, so it is still Oct 31. "instant − 4h" gives Nov 1.
    @Test func fallBackDayUsesWallClock() {
        #expect(LocalDay(of: utc(2026, 11, 1, 8, 30), in: newYork, rolloverHour: 4) == day("2026-10-31"))
    }

    @Test func weekdaysAndISOWeekStartOnMonday() {
        #expect(day("1970-01-01").weekday == .thursday)
        #expect(day("2026-11-08").weekday == .sunday)
        #expect(day("2026-11-09").weekday == .monday)
        // Sunday belongs to the week that started the Monday before, in every locale.
        #expect(day("2026-11-08").weekStart == day("2026-11-02"))
        #expect(day("2026-11-09").weekStart == day("2026-11-09"))
        #expect(!day("2026-11-08").isInSameWeek(as: day("2026-11-09")))
        // A week that crosses a year boundary.
        #expect(day("2027-01-03").weekStart == day("2026-12-28"))
    }

    @Test func arithmeticCrossesMonthsLeapDaysAndYears() {
        #expect(day("2028-02-28").adding(days: 1) == day("2028-02-29"))
        #expect(day("2027-02-28").adding(days: 1) == day("2027-03-01"))
        #expect(day("2026-12-31").adding(days: 1) == day("2027-01-01"))
        #expect(day("2026-03-01").adding(days: -1) == day("2026-02-28"))
        #expect(day("2000-02-28").adding(days: 1) == day("2000-02-29"))
        #expect(day("2100-02-28").adding(days: 1) == day("2100-03-01"))
    }

    @Test func ordinalRoundTripsAcrossCenturies() {
        for ordinal in stride(from: -800_000, through: 800_000, by: 997) {
            let d = LocalDay(ordinal: ordinal)
            #expect(LocalDay(year: d.year, month: d.month, day: d.day)?.ordinal == ordinal)
        }
    }

    @Test func stringFormRoundTripsAndRejectsGarbage() {
        #expect(day("2026-03-07").description == "2026-03-07")
        #expect(LocalDay(string: "2026-02-30") == nil)
        #expect(LocalDay(string: "2028-02-29") != nil)
        #expect(LocalDay(string: "2000-02-29") != nil)
        #expect(LocalDay(string: "2100-02-29") == nil)
        #expect(LocalDay(string: "2027-02-29") == nil)
        #expect(LocalDay(string: "2026-3-7") == nil)
        #expect(LocalDay(string: "2026-13-01") == nil)
        #expect(LocalDay(string: "") == nil)
    }

    @Test func nextRolloverIsTheNextWallClockRolloverHour() {
        // 23:00 on Nov 9 → 04:00 on Nov 10.
        let next = nextRollover(after: instant(2026, 11, 9, 23, zone: "America/New_York"), in: newYork, rolloverHour: 4)
        #expect(next == instant(2026, 11, 10, 4, zone: "America/New_York"))
        // 02:00 on Nov 10 is still Nov 9's day, so the next rollover is 04:00 the same morning.
        let early = nextRollover(after: instant(2026, 11, 10, 2, zone: "America/New_York"), in: newYork, rolloverHour: 4)
        #expect(early == instant(2026, 11, 10, 4, zone: "America/New_York"))
    }
}
