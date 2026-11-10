import ClewCore
import ClewDomain
import Foundation
import Testing

/// 2026-`mo`-`d` at `h:m` in New York (Clew's day rolls over at 4 a.m.).
private func at(_ d: Int, _ h: Int, _ m: Int = 0, month mo: Int = 11) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: mo, day: d, hour: h, minute: m))!
}

private let eightToNine = TimeSlot(hour: 8, minute: 0, minutes: 60)!

/// SPEC decision 2026-11-10, "A repeating task's time slot".
@Suite struct SlotTests {
    let store = FakeStore()
    let clock = TestClock(at(10, 5))            // Tuesday, before the slot
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }

    private func habit(_ schedule: Schedule = .daily, slot: TimeSlot? = eightToNine) throws -> UUID {
        try clew.addItem(NewItem(title: "stretch", shape: .habit(schedule), slot: slot)).id
    }
    private func goal(_ target: Int = 30) throws -> UUID {
        try clew.addItem(NewItem(title: "read", shape: .goal(target: target, schedule: .daily), slot: eightToNine)).id
    }
    private func blocks(_ id: UUID, day: Int = 10) -> [TimeBlock] {
        store.state.timeBlocks.values.filter { $0.itemId == id && $0.localDay.day == day }.sorted { $0.placedAt < $1.placedAt }
    }
    private func ticks(_ id: UUID) -> [CheckIn] {
        store.state.checkIns.values.filter { $0.itemId == id && !$0.isVoided }.sorted { $0.at < $1.at }
    }
    private func settle(at time: Date) throws { clock.set(time); try clew.settleBlocks() }

    @Test func onlyRepeatingTasksHaveASlot() throws {
        #expect(throws: ClewError.notAllowed) {
            try clew.addItem(NewItem(title: "once", shape: .today, slot: eightToNine))
        }
        let once = try clew.addItem(NewItem(title: "once", shape: .today)).id
        #expect(throws: ClewError.notAllowed) {
            try clew.editItem(id: once, ItemEdit(title: "once", url: nil, slot: .set(eightToNine)))
        }
        #expect(TimeSlot(hour: 8, minute: 10, minutes: 60) == nil && TimeSlot(hour: 8, minute: 0, minutes: 50) == nil)
        #expect(TimeSlot(hour: 8, minute: 0, minutes: 120) != nil)
    }

    @Test func eachDueDayGetsTheSlotBlockOnce() throws {
        let id = try habit()
        try settle(at: at(10, 5))
        let b = try #require(blocks(id).first)
        #expect(b.origin == .slot && b.start == at(10, 8) && b.minutes == 60 && blocks(id).count == 1)
        try settle(at: at(10, 6))
        #expect(blocks(id).count == 1)
        #expect(try clew.timeline().placedItems == [id])         // it lives on the timeline
        try settle(at: at(11, 5))                                 // Wednesday
        #expect(blocks(id, day: 11).first?.start == at(11, 8))
    }

    @Test func aDayTheTaskIsNotDueHasNone() throws {
        let id = try habit(.weekdays([.wednesday]))
        try settle(at: at(10, 5))
        #expect(blocks(id).isEmpty)
        try settle(at: at(11, 5))
        #expect(blocks(id, day: 11).count == 1)
    }

    @Test func aTaskDoneAlreadyGetsNoSlotBlock() throws {
        let id = try habit()
        clock.set(at(10, 4, 30)); try clew.checkIn(itemId: id)       // done before Clew settled
        try settle(at: at(10, 5))
        #expect(blocks(id).isEmpty)
    }

    @Test func aSlotThatHasStartedIsNotPlacedThatDay() throws {
        let id = try habit()
        try settle(at: at(10, 8, 30))                             // the Mac was off until 8:30
        #expect(blocks(id).isEmpty)
        #expect(try clew.today().rows.contains { $0.id == id })
    }

    @Test func aBlockTodayLiveOrRemovedMeansNoSlotBlock() throws {
        let id = try habit()
        try settle(at: at(10, 5))
        try clew.removeBlock(id: try #require(blocks(id).first).id)
        try settle(at: at(10, 6))
        #expect(blocks(id).count == 1 && blocks(id).first?.removedAt != nil)      // not back today
        let other = try habit(slot: TimeSlot(hour: 15, minute: 0, minutes: 30))
        // The slot appears only after a block placed by hand was taken back off.
        clock.set(at(10, 4, 30))
        let byHand = try clew.placeOnTimeline(itemId: other, start: at(10, 11))
        try clew.removeBlock(id: byHand.id)
        try settle(at: at(10, 5))
        #expect(blocks(other).count == 1)
    }

    @Test func itNeverTicksByItselfItAsks() throws {
        let id = try habit()
        try settle(at: at(10, 5))
        let b = try #require(blocks(id).first)
        try settle(at: at(10, 9))
        #expect(ticks(id).isEmpty)
        #expect(store.state.timeBlocks[b.id]?.askedAt == at(10, 9) && store.state.timeBlocks[b.id]?.decidedAt == nil)
        #expect(try clew.timeline().blocks.first?.state == .asking)
        #expect(try clew.askingBlockIds() == [b.id])
        try settle(at: at(10, 9, 5))
        #expect(store.state.timeBlocks[b.id]?.askedAt == at(10, 9))   // asked once
        // Any hand tick answers it, for good.
        clock.set(at(10, 9, 10))
        let hand = try clew.checkIn(itemId: id)
        try settle(at: at(10, 9, 11))
        #expect(store.state.timeBlocks[b.id]?.decidedAt == at(10, 9, 11) && ticks(id).map(\.id) == [hand.id])
        #expect(try clew.askingBlockIds().isEmpty)
        try clew.undoToday(itemId: id)
        try settle(at: at(10, 10))
        #expect(ticks(id).isEmpty && store.state.timeBlocks[b.id]?.askedAt == at(10, 9))
        #expect(try clew.timeline().blocks.first?.state == .skipped)
    }

    @Test func doneBeforeItsEndItStaysQuiet() throws {
        let id = try habit()
        try settle(at: at(10, 5))
        clock.set(at(10, 7)); try clew.checkIn(itemId: id)
        try settle(at: at(10, 9, 1))
        let b = try #require(blocks(id).first)
        #expect(b.askedAt == nil && b.decidedAt != nil)
    }

    @Test func aGoalIsAnsweredByItsFirstUnusedPlusOne() throws {
        let id = try goal()
        try settle(at: at(10, 5))
        try settle(at: at(10, 9))
        let b = try #require(blocks(id).first)
        try clew.answerSlotBlock(id: b.id)                       // the notification's +1
        #expect(ticks(id).count == 1 && ticks(id).first?.source == .notification)
        #expect(store.state.timeBlocks[b.id]?.coverId == ticks(id).first?.id)
        #expect(throws: ClewError.notAllowed) { try clew.answerSlotBlock(id: b.id) }
    }

    @Test func theQuestionEndsAtTheRollover() throws {
        let id = try habit()
        try settle(at: at(10, 5))
        try settle(at: at(10, 9))
        let b = try #require(blocks(id).first)
        clock.set(at(11, 7))                                      // Wednesday, before Clew settles
        #expect(throws: ClewError.notAllowed) { try clew.answerSlotBlock(id: b.id) }
        #expect(ticks(id).isEmpty)
        try settle(at: at(11, 7))
        #expect(store.state.timeBlocks[b.id]?.decidedAt == at(11, 7) && ticks(id).isEmpty)
        #expect(try clew.lateTicks().isEmpty)
        #expect(throws: ClewError.notAllowed) { try clew.answerSlotBlock(id: b.id) }
    }

    @Test func withTheTimelineOffNothingIsPlacedOrAsked() throws {
        let id = try habit()
        try clew.setTimelineShown(false)
        try settle(at: at(10, 5))
        #expect(blocks(id).isEmpty)
        try clew.setTimelineShown(true)
        try settle(at: at(10, 6))
        let b = try #require(blocks(id).first)
        try clew.setTimelineShown(false)
        #expect(try clew.plannedNotifications().filter { $0.id.hasPrefix("clew.ask.") }.isEmpty)
        try settle(at: at(10, 9, 30))
        #expect(store.state.timeBlocks[b.id]?.askedAt == nil)
        #expect(try clew.plannedNotifications().filter { $0.id.hasPrefix("clew.ask.") }.isEmpty)
        try clew.setTimelineShown(true)
        try settle(at: at(10, 9, 40))                             // back on: it asks, quietly
        #expect(store.state.timeBlocks[b.id]?.askedAt == at(10, 9, 40))
    }

    @Test func directChangesAreForTodayOnly() throws {
        let id = try habit()
        try settle(at: at(10, 5))
        let b = try #require(blocks(id).first)
        try clew.moveBlock(id: b.id, start: at(10, 10))
        #expect(store.state.timeBlocks[b.id]?.touchedAt == at(10, 5))
        // Edit now leaves today's moved block alone; tomorrow follows the slot.
        try clew.editItem(id: id, ItemEdit(title: "stretch", url: nil, schedule: .daily,
                                           slot: .set(TimeSlot(hour: 7, minute: 0, minutes: 30))))
        #expect(store.state.timeBlocks[b.id]?.start == at(10, 10))
        try settle(at: at(11, 5))
        #expect(blocks(id, day: 11).first?.start == at(11, 7) && blocks(id, day: 11).first?.minutes == 30)
    }

    @Test func editMovesAnUntouchedBlockThatHasNotStarted() throws {
        let id = try habit()
        try settle(at: at(10, 5))
        let b = try #require(blocks(id).first)
        clock.set(at(10, 6))
        try clew.editItem(id: id, ItemEdit(title: "stretch", url: nil, schedule: .daily,
                                           slot: .set(TimeSlot(hour: 10, minute: 30, minutes: 45))))
        #expect(store.state.timeBlocks[b.id]?.start == at(10, 10, 30) && store.state.timeBlocks[b.id]?.minutes == 45)
        #expect(store.state.timeBlocks[b.id]?.touchedAt == nil)
        // To a time that has started: removed, nothing ticks, nothing comes back today.
        try clew.editItem(id: id, ItemEdit(title: "stretch", url: nil, schedule: .daily,
                                           slot: .set(TimeSlot(hour: 5, minute: 0, minutes: 30))))
        #expect(store.state.timeBlocks[b.id]?.removedAt == at(10, 6))
        try settle(at: at(10, 6, 1))
        #expect(blocks(id).count == 1 && ticks(id).isEmpty)
    }

    @Test func turningTheSlotOffRemovesTodaysUntouchedBlock() throws {
        let id = try habit()
        try settle(at: at(10, 5))
        try clew.editItem(id: id, ItemEdit(title: "stretch", url: nil, schedule: .daily, slot: .set(nil)))
        #expect(blocks(id).first?.removedAt == at(10, 5) && store.state.items[id]?.slot == nil)
        // .keep leaves the slot alone.
        try clew.editItem(id: id, ItemEdit(title: "renamed", url: nil, schedule: .daily, slot: .set(eightToNine)))
        try clew.editItem(id: id, ItemEdit(title: "again", url: nil, schedule: .daily))
        #expect(store.state.items[id]?.slot == eightToNine)
    }

    @Test func aSlotSetTodayCountsToday() throws {
        let id = try habit(slot: nil)
        clock.set(at(10, 7))
        try clew.editItem(id: id, ItemEdit(title: "stretch", url: nil, schedule: .daily, slot: .set(eightToNine)))
        try settle(at: at(10, 7, 1))
        #expect(blocks(id).first?.start == at(10, 8))
    }

    @Test func aReachedGoalGoesBackToTheListAndStays() throws {
        let id = try goal(1)
        try settle(at: at(10, 5))
        clock.set(at(10, 6)); try clew.checkIn(itemId: id)            // 1/1 by hand, from the block's menu
        try settle(at: at(10, 6, 1))
        #expect(try clew.timeline().placedItems.isEmpty)
        #expect(blocks(id).first?.releasedAt == at(10, 6, 1))
        #expect(throws: ClewError.notAllowed) { try clew.placeOnTimeline(itemId: id, start: at(10, 12)) }
        try clew.startNextRound(itemId: id)
        try settle(at: at(10, 6, 2))
        #expect(try clew.timeline().placedItems.isEmpty)               // stays in the list
        try clew.placeOnTimeline(itemId: id, start: at(10, 12))
        #expect(try clew.timeline().placedItems == [id])                // until placed again
    }

    @Test func aBlockByHandStillTicksAtItsEnd() throws {
        let id = try habit(slot: nil)
        try clew.placeOnTimeline(itemId: id, start: at(10, 6))
        try settle(at: at(10, 6, 30))
        #expect(ticks(id).first?.source == .timeline)
    }

    @Test func focusDoneCountsTheAnswerAsTheSittingsTick() throws {
        let id = try goal()
        try settle(at: at(10, 5))
        clock.set(at(10, 8, 40)); try clew.startFocus(itemId: id, minutes: 25)
        try settle(at: at(10, 9))
        try clew.answerSlotBlock(id: try #require(blocks(id).first).id)
        clock.set(at(10, 9, 5))
        #expect(try clew.finishFocus() == nil && ticks(id).count == 1)
    }

    @Test func slotNotificationsAskAtTheEnd() throws {
        let id = try habit()
        try settle(at: at(10, 5))
        let b = try #require(blocks(id).first)
        let asks = try clew.plannedNotifications().filter { $0.id.hasPrefix("clew.ask.") }
        #expect(asks.map(\.fireAt) == [at(10, 9)])
        #expect(asks.first?.content == .slotAsks(blockId: b.id, itemId: id, title: "stretch", isGoal: false))
        try clew.setBlockAlerts(false)
        #expect(try clew.plannedNotifications().filter { $0.id.hasPrefix("clew.ask.") }.isEmpty)
    }

    @Test func aSkippedHourMovesToTheEndOfTheGap() throws {
        // 2027-03-14 in New York: 2:00–3:00 does not exist; a 2:30 slot starts at 3:00.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let day = LocalDay(string: "2027-03-13")!                     // its night holds the gap
        let slot = TimeSlot(hour: 2, minute: 30, minutes: 30)!
        let place = try #require(clew.slotPlacement(slot, on: day))
        #expect(place.start == cal.date(from: DateComponents(year: 2027, month: 3, day: 14, hour: 3)))
        // 1:30 on 2026-11-01 happens twice: the first one.
        let fall = try #require(clew.slotPlacement(TimeSlot(hour: 1, minute: 30, minutes: 30)!,
                                                   on: LocalDay(string: "2026-10-31")!))
        #expect(fall.start == Date(timeIntervalSince1970: 1_793_511_000))          // 05:30 UTC (EDT)
        // Near the day's end a slot is cut at 4 a.m.
        #expect(clew.slotPlacement(TimeSlot(hour: 3, minute: 30, minutes: 120)!, on: LocalDay(string: "2026-11-10")!)?.minutes == 30)
    }
}
