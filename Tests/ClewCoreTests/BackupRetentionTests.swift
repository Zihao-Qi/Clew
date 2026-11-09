import ClewCore
import ClewDomain
import Testing

@Suite struct BackupRetentionTests {
    private func day(_ s: String) -> LocalDay { LocalDay(string: s)! }

    /// Worked by hand: today is Monday Nov 9; a backup exists for every day.
    /// Dailies: Oct 27 … Nov 9 (14). Older weeks, newest each: Oct 26 (its week starts
    /// Oct 26 Mon … only Oct 26 is older than the cutoff), Oct 25, 18, 11, 4, Sep 27,
    /// 20, 13 (8).
    @Test func keepsFourteenDailiesAndEightOlderWeeklies() {
        let today = day("2026-11-09")
        let all = (0..<120).map { today.adding(days: -$0) }
        let kept = BackupRetention.keep(all, today: today)
        let dailies = Set((0..<14).map { today.adding(days: -$0) })
        let weeklies: Set<LocalDay> = ["2026-10-26", "2026-10-25", "2026-10-18", "2026-10-11", "2026-10-04",
                                       "2026-09-27", "2026-09-20", "2026-09-13"].reduce(into: []) { $0.insert(day($1)) }
        #expect(kept == dailies.union(weeklies))
        #expect(kept.count == 22)
    }

    @Test func sparseBackupsKeepOnePerWeekForEightOlderWeeks() {
        let today = day("2026-11-09")
        // Only on Wednesdays, for 12 weeks: Nov 4 and Oct 28 are within 14 days; the next 8 are weeklies.
        let wednesdays = (0..<12).map { day("2026-11-04").adding(days: -7 * $0) }
        let kept = BackupRetention.keep(wednesdays, today: today)
        #expect(kept == Set(wednesdays.prefix(2 + 8)))
    }

    @Test func futureDatedBackupsAreNotKept() {
        let today = day("2026-11-09")
        #expect(BackupRetention.keep([day("2026-11-10"), today], today: today) == [today])
    }
}
