import ClewCore
import ClewDomain
import Foundation
import Testing

private let ny = TimeZone(identifier: "America/New_York")!
private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = ny
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}
private func t(_ h: Int, _ m: Int = 0) -> TimeOfDay { TimeOfDay(hour: h, minute: m)! }
private func d(_ s: String) -> LocalDay { LocalDay(string: s)! }
private let t0 = at(2026, 11, 1, 8)

private func item(_ kind: ItemKind, _ schedule: Schedule = .unscheduled, planned: LocalDay? = nil,
                  url: URL? = nil, sortKey: Double = 1) -> Item {
    Item(id: UUID(), kind: kind, title: "\(kind)", url: url, schedule: schedule,
         progress: kind == .goal ? .counter(target: 30) : .none, state: .active, plannedDay: planned,
         sortKey: sortKey, source: .user, createdAt: t0, updatedAt: t0)
}
private func tick(_ i: Item, _ day: String) -> CheckIn {
    CheckIn(id: UUID(), itemId: i.id, localDay: d(day), at: t0, timeZoneId: "America/New_York", source: .user)
}
private func reminder(_ i: Item, _ time: TimeOfDay, enabled: Bool = true, deleted: Bool = false) -> Reminder {
    Reminder(id: UUID(), itemId: i.id, time: time, enabled: enabled, updatedAt: t0, deletedAt: deleted ? t0 : nil)
}
private let off = SummarySettings.defaults
private let on = SummarySettings(morningEnabled: true, morningTime: t(9), eveningEnabled: true, eveningTime: t(21))

/// Wednesday Nov 11, 2026, 08:00 in New York, unless a test says otherwise.
private func plan(now: Date = at(2026, 11, 11, 8), items: [Item], ticks: [CheckIn] = [],
                  reminders: [Reminder] = [], summaries: SummarySettings = off) -> [PlannedNotification] {
    var facts: [UUID: ItemFacts] = [:]
    for i in items {
        let mine = ticks.filter { $0.itemId == i.id }
        facts[i.id] = ItemFacts(recent: mine, progressAmount: mine.reduce(0) { $0 + $1.amount })
    }
    return NotificationPlanner.plan(now: now, zone: ny, rolloverHour: 4, items: items, facts: facts,
                                    reminders: reminders, summaries: summaries)
}

@Suite struct SummaryPlanTests {
    @Test func summariesAreOffUntilSwitchedOn() {
        #expect(plan(items: [item(.habit, .daily)]).isEmpty)
    }

    @Test func morningAndEveningForEachOfSevenDaysWithItems() {
        let p = plan(items: [item(.habit, .daily), item(.habit, .weekdays([.saturday]), sortKey: 2)], summaries: on)
        let mornings = p.filter { $0.id.hasPrefix("clew.morning.") }
        #expect(mornings.map(\.id) == (11...17).map { "clew.morning.2026-11-\($0)" })
        #expect(mornings.first?.fireAt == at(2026, 11, 11, 9))
        // Saturday Nov 14 has both items.
        #expect(mornings.map(\.content)[3] == .morning(total: 2))
        #expect(mornings.map(\.content)[0] == .morning(total: 1))
        #expect(p.filter { $0.id.hasPrefix("clew.evening.") }.count == 7)
    }

    @Test func timesAlreadyPassedTodayAreNotPlanned() {
        let p = plan(now: at(2026, 11, 11, 10), items: [item(.habit, .daily)], summaries: on)
        #expect(!p.contains { $0.id == "clew.morning.2026-11-11" })
        #expect(p.contains { $0.id == "clew.evening.2026-11-11" })
    }

    @Test func eveningSaysKDoneOnlyAfterATick_otherwiseAKindLine() {
        let a = item(.habit, .daily), b = item(.habit, .daily, sortKey: 2)
        let ticked = plan(items: [a, b], ticks: [tick(a, "2026-11-11")], summaries: on)
        #expect(ticked.first { $0.id == "clew.evening.2026-11-11" }?.content == .evening(done: 1, total: 2))
        let quiet = plan(items: [a, b], summaries: on)
        #expect(quiet.first { $0.id == "clew.evening.2026-11-11" }?.content
                == .eveningKindLine(index: NotificationPlanner.kindLine(for: d("2026-11-11"))))
        // Future evenings are pre-scheduled with a kind line: "0/N" can never fire.
        let future = ticked.filter { $0.id.hasPrefix("clew.evening.") && $0.id != "clew.evening.2026-11-11" }
        #expect(future.count == 6)
        #expect(future.allSatisfy { if case .eveningKindLine = $0.content { true } else { false } })
    }

    @Test func noSummaryOnADayWithNothingOnTheList() {
        let p = plan(items: [item(.habit, .weekdays([.friday]))], summaries: on)
        #expect(Set(p.map(\.id)) == ["clew.morning.2026-11-13", "clew.evening.2026-11-13"])
    }

    @Test func kindLinesNeverRepeatOnConsecutiveDays() {
        for o in 0..<400 {
            let day = d("2026-01-01").adding(days: o)
            #expect(NotificationPlanner.kindLine(for: day) != NotificationPlanner.kindLine(for: day.adding(days: 1)))
            #expect((0..<NotificationPlanner.kindLineCount).contains(NotificationPlanner.kindLine(for: day)))
        }
    }
}

@Suite struct ReminderPlanTests {
    @Test func aDoneItemIsNotRemindedToday_butADailyHabitIsTomorrow() {
        let h = item(.habit, .daily)
        let p = plan(items: [h], ticks: [tick(h, "2026-11-11")], reminders: [reminder(h, t(18))])
        let id = "clew.reminder.\(h.id.uuidString)"
        #expect(p.map(\.id) == (12...17).map { "\(id).2026-11-\($0)" })
        #expect(p.first?.fireAt == at(2026, 11, 12, 18))
    }

    @Test func anUnfinishedOnceItemIsRemindedEachDayItIsOnTheList() {
        let o = item(.once, planned: d("2026-11-09"))
        let p = plan(items: [o], reminders: [reminder(o, t(18))])
        #expect(p.count == 7)
        let future = item(.once, planned: d("2026-11-14"))
        #expect(plan(items: [future], reminders: [reminder(future, t(18))]).count == 4) // Nov 14…17
    }

    @Test func weekdayAndWeeklyHabitsFollowTheirDueDays() {
        let w = item(.habit, .weekdays([.monday, .friday]))
        let p = plan(items: [w], reminders: [reminder(w, t(7, 30))])
        #expect(p.map(\.fireAt) == [at(2026, 11, 13, 7, 30), at(2026, 11, 16, 7, 30)])
        // timesPerWeek(2) already met Mon + Tue: no reminders until next Monday.
        let n = item(.habit, .timesPerWeek(2))
        let q = plan(items: [n], ticks: [tick(n, "2026-11-09"), tick(n, "2026-11-10")], reminders: [reminder(n, t(18))])
        #expect(q.map(\.fireAt) == [at(2026, 11, 16, 18), at(2026, 11, 17, 18)])
    }

    /// ARCHITECTURE §4.3: a time before the rollover hour belongs to the previous day.
    @Test func aOneAmReminderFiresAfterMidnight() {
        let h = item(.habit, .weekdays([.wednesday]))
        let p = plan(items: [h], reminders: [reminder(h, t(1))])
        #expect(p.map(\.fireAt) == [at(2026, 11, 12, 1)])
        #expect(p.first?.id.hasSuffix(".2026-11-11") == true)
    }

    @Test func disabledDeletedAndUnknownRemindersAreIgnored() {
        let h = item(.habit, .daily)
        let stranger = item(.habit, .daily)
        #expect(plan(items: [h], reminders: [reminder(h, t(18), enabled: false)]).isEmpty)
        #expect(plan(items: [h], reminders: [reminder(h, t(18), deleted: true)]).isEmpty)
        #expect(plan(items: [h], reminders: [reminder(stranger, t(18))]).isEmpty)
    }

    @Test func actionsDependOnKindAndLink() {
        let link = item(.link, planned: d("2026-11-11"), url: URL(string: "https://a.example"))
        let habit = item(.habit, .daily, sortKey: 2)
        let p = plan(now: at(2026, 11, 17, 8), items: [link, habit],
                     reminders: [reminder(link, t(18)), reminder(habit, t(19))])
        #expect(p.prefix(2).map(\.content) == [
            .reminder(itemId: link.id, title: "link", canOpen: true, canMoveToLater: true),
            .reminder(itemId: habit.id, title: "habit", canOpen: false, canMoveToLater: false),
        ])
    }

    @Test func atMost64_earliestFirst() {
        let items = (0..<20).map { item(.habit, .daily, sortKey: Double($0)) }
        let p = plan(items: items, reminders: items.map { reminder($0, t(18)) }, summaries: on)
        #expect(p.count == 64)
        #expect(p.map(\.fireAt) == p.map(\.fireAt).sorted())
        #expect(Set(p.map(\.id)).count == 64)
        #expect(p.first?.id == "clew.morning.2026-11-11")
    }
}

@Suite struct NotificationDiffTests {
    @Test func onlyChangesAreTouched() {
        let desired = ["clew.a": "1", "clew.b": "2", "clew.new": "9"]
        let pending = ["clew.a": "1", "clew.b": "old", "clew.stale": "5", "other.app": "x"]
        let (remove, add) = NotificationPlanner.diff(desired: desired, pending: pending)
        #expect(remove == ["clew.b", "clew.stale"])
        #expect(add == ["clew.b", "clew.new"])
    }

    @Test func identicalSetsChangeNothing() {
        let same = ["clew.a": "1"]
        let (remove, add) = NotificationPlanner.diff(desired: same, pending: same)
        #expect(remove.isEmpty && add.isEmpty)
    }
}
