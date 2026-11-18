import ClewCore
import ClewDomain
import Testing

/// The quarter-hour time field (user, 2026-11-18).
@Suite struct QuarterTimeTests {
    private func t(_ h: Int, _ m: Int) -> TimeOfDay { TimeOfDay(hour: h, minute: m)! }

    @Test func arrowsOnTheMinutesStepAQuarter() {
        #expect(QuarterTime.stepped(from: t(8, 0), to: t(8, 1)) == t(8, 15))      // up
        #expect(QuarterTime.stepped(from: t(8, 15), to: t(8, 14)) == t(8, 0))     // down
        // The field carries into the hour (found in the real field: 8:00 ↓ showed 7:59).
        #expect(QuarterTime.stepped(from: t(8, 45), to: t(8, 46)) == t(9, 0))
        #expect(QuarterTime.stepped(from: t(8, 0), to: t(7, 59)) == t(7, 45))
        #expect(QuarterTime.stepped(from: t(0, 0), to: t(23, 59)) == t(23, 45))   // past midnight
        #expect(QuarterTime.stepped(from: t(23, 45), to: t(23, 46)) == t(0, 0))
        #expect(QuarterTime.stepped(from: t(8, 7), to: t(8, 8)) == t(8, 15))      // from a typed :07, up
        #expect(QuarterTime.stepped(from: t(8, 7), to: t(8, 6)) == t(8, 0))       // and down
    }

    @Test func theHourAndTypedDigitsAreKept() {
        #expect(QuarterTime.stepped(from: t(8, 15), to: t(9, 15)) == t(9, 15))
        #expect(QuarterTime.stepped(from: t(8, 0), to: t(8, 3)) == t(8, 3))       // typing "3…"
        #expect(QuarterTime.stepped(from: t(8, 15), to: t(8, 15)) == t(8, 15))
    }

    @Test func leavingTheFieldRoundsToTheNearestQuarter() {
        #expect(QuarterTime.nearest(t(8, 7)) == t(8, 0))
        #expect(QuarterTime.nearest(t(8, 8)) == t(8, 15))
        #expect(QuarterTime.nearest(t(8, 52)) == t(8, 45))
        #expect(QuarterTime.nearest(t(8, 53)) == t(9, 0))
        #expect(QuarterTime.nearest(t(23, 55)) == t(0, 0))
        #expect(QuarterTime.nearest(t(8, 30)) == t(8, 30))
    }
}
