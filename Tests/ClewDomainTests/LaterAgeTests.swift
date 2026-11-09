import ClewDomain
import Testing

@Suite struct LaterAgeTests {
    @Test func asksFromSixWeeks() {
        let today = day("2026-11-09")
        #expect(LaterAge.daysWaiting(lastTouched: day("2026-09-28"), today: today) == 42)
        #expect(LaterAge.asksStillWant(daysWaiting: 42))
        #expect(!LaterAge.asksStillWant(daysWaiting: 41))
        #expect(LaterAge.daysWaiting(lastTouched: day("2026-11-10"), today: today) == 0) // never negative
    }
}
