import ClewCore
import ClewDomain
import Foundation
import Testing

/// 2026-11-`d` at `h:m:s` in New York (Clew's day rolls over at 4 a.m.).
private func at(_ d: Int, _ h: Int, _ m: Int = 0, _ s: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m, second: s))!
}

private let tuesday = LocalDay(string: "2026-11-10")!

/// SPEC decision 2026-11-10, day timeline: a block's end ticks the task, once.
@Suite struct TimelineTests {
    let store = FakeStore()
    let clock = TestClock(at(10, 9))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }

    private func task(_ title: String = "write") throws -> UUID {
        try clew.addItem(NewItem(title: title, shape: .today)).id
    }
    private func goal(_ target: Int = 30) throws -> UUID {
        try clew.addItem(NewItem(title: "read", shape: .goal(target: target, schedule: .daily))).id
    }
    private func ticks(_ id: UUID, source: Source? = nil) -> [CheckIn] {
        store.state.checkIns.values.filter { $0.itemId == id && !$0.isVoided && (source == nil || $0.source == source) }
            .sorted { $0.at < $1.at }
    }
    private func block(_ id: UUID) -> TimeBlock { store.state.timeBlocks[id]! }
    private func settle(at time: Date) throws { clock.set(time); try clew.settleBlocks() }
    private func row(_ id: UUID) throws -> TodayRow? { try clew.today().rows.first { $0.id == id } }

    // MARK: Placing

    @Test func aDroppedTaskGetsThirtyMinutesOnAQuarterHourOfToday() throws {
        let id = try task()
        let b = try clew.placeOnTimeline(itemId: id, start: at(10, 10))
        #expect(b.start == at(10, 10) && b.minutes == 30 && b.localDay == tuesday && b.placedAt == at(10, 9))
        #expect(throws: ClewError.notAllowed) { try clew.placeOnTimeline(itemId: id, start: at(10, 10, 5)) }
        #expect(throws: ClewError.notAllowed) { try clew.placeOnTimeline(itemId: id, start: at(10, 3, 45)) }  // yesterday
        #expect(throws: ClewError.notAllowed) { try clew.placeOnTimeline(itemId: id, start: at(11, 4)) }      // tomorrow
        // Near the day's end it is cut to fit: 3:45 leaves 15 minutes.
        let late = try clew.placeOnTimeline(itemId: try task("late"), start: at(11, 3, 45))
        #expect(late.minutes == 15 && late.end == at(11, 4))
        #expect(throws: ClewError.invalidMinutes(max: 15)) {
            try clew.placeOnTimeline(itemId: try task("long"), start: at(11, 3, 45), minutes: 30)
        }
    }

    @Test func onlyTasksOnTodaysListCanBePlaced() throws {
        let later = try clew.addItem(NewItem(title: "someday", shape: .later)).id
        #expect(throws: ClewError.notAllowed) { try clew.placeOnTimeline(itemId: later, start: at(10, 10)) }
        try clew.importExternal(ImportBatch(source: .extensionYouTube,
            entries: [ExternalEntry(externalRef: "aaaaaaaaaaa", title: "v")], listTotal: 1))
        let video = try #require(store.state.items.values.first { $0.externalRef == "aaaaaaaaaaa" }).id
        #expect(throws: ClewError.notAllowed) { try clew.placeOnTimeline(itemId: video, start: at(10, 10)) }
    }

    @Test func draggingTheRowAgainMovesItsOpenBlockElseAddsOne() throws {
        let id = try task()
        let first = try clew.placeOnTimeline(itemId: id, start: at(10, 10))
        let moved = try clew.placeOnTimeline(itemId: id, start: at(10, 14))
        #expect(moved.id == first.id && moved.start == at(10, 14) && store.state.timeBlocks.count == 1)
        // Once every block has ended, the same drag adds a second one.
        try settle(at: at(10, 15))
        let second = try clew.placeOnTimeline(itemId: id, start: at(10, 16))
        #expect(second.id != first.id && store.state.timeBlocks.count == 2)
        // Dragged near the day's end, a longer block is cut to fit, as the drop shows it.
        try clew.resizeBlock(id: second.id, minutes: 45)
        let cut = try clew.placeOnTimeline(itemId: id, start: at(11, 3, 45))
        #expect(cut.id == second.id && cut.minutes == 15)
    }

    @Test func blockLengthsAreWholeQuarterHours() throws {
        let b = try clew.placeOnTimeline(itemId: try task(), start: at(10, 10))
        for bad in [20, 10, 0] {
            #expect(throws: ClewError.self) { try clew.resizeBlock(id: b.id, minutes: bad) }
        }
        #expect(try clew.resizeBlock(id: b.id, minutes: 15).minutes == 15)
    }

    @Test func anotherBlockGoesRightAfterWithTheSameLength() throws {
        let id = try goal()
        let b = try clew.placeOnTimeline(itemId: id, start: at(10, 10), minutes: 45)
        let next = try clew.addBlock(after: b.id)
        #expect(next.start == b.end && next.minutes == 45 && next.itemId == id)
        let late = try clew.placeOnTimeline(itemId: try task("late"), start: at(11, 3, 30))
        #expect(!clew.canAddBlock(after: late))
        #expect(throws: ClewError.invalidMinutes(max: 0)) { try clew.addBlock(after: late.id) }
    }

    // MARK: A new task from the timeline (SPEC 2026-11-13)

    @Test func doubleClickMakesATodayTaskAndItsBlockThere() throws {
        let earlier = try task("earlier")
        let made = try clew.addOnTimeline(title: "  Write intro ", start: at(10, 10, 15))
        let item = made.item
        #expect(item.kind == .once && item.title == "Write intro" && item.plannedDay == tuesday && item.source == .user)
        #expect(made.block.itemId == item.id && made.block.start == at(10, 10, 15) && made.block.minutes == 30
                && made.block.localDay == tuesday && made.block.decidedAt == nil)
        // On Today, after what was there (its row's place, once back in the list, is at the end).
        #expect(try clew.today().rows.map(\.id) == [earlier, item.id])
        // It lives on the timeline, not in the list.
        #expect(try clew.timeline().placedItems == [item.id])
        // A link keeps its fetched title's origin.
        let link = try clew.addOnTimeline(title: "Swift Testing", titleOrigin: .fetched,
                                          url: URL(string: "https://example.com/a"), start: at(10, 11))
        #expect(link.item.kind == .once && link.item.titleOrigin == .fetched && link.item.url?.host == "example.com")
    }

    @Test func aRefusedNameOrStartMakesNothing() throws {
        // The box opened before 4 a.m. and Return came after the rollover: 3:30 is yesterday's now.
        for (now, start) in [(at(10, 9), at(10, 10, 5)),      // not on a quarter hour
                             (at(10, 9), at(11, 4)),          // tomorrow
                             (at(11, 4, 1), at(11, 3, 30))] { // after the rollover
            clock.set(now)
            #expect(throws: ClewError.notAllowed) { try clew.addOnTimeline(title: "write", start: start) }
        }
        clock.set(at(10, 9))
        #expect(throws: ClewError.emptyTitle) { try clew.addOnTimeline(title: "   ", start: at(10, 10)) }
        #expect(throws: ClewError.self) {
            try clew.addOnTimeline(title: String(repeating: "x", count: 1000), start: at(10, 10))
        }
        #expect(store.state.items.isEmpty && store.state.timeBlocks.isEmpty)
    }

    @Test func nearFourAMTheNewBlockIsCutToFit() throws {
        let made = try clew.addOnTimeline(title: "late", start: at(11, 3, 45))
        #expect(made.block.minutes == 15 && made.block.end == at(11, 4))
    }

    @Test func aPastHourMakesTheTaskDoneAndNotFinishedUndoesIt() throws {
        let made = try clew.addOnTimeline(title: "ran", start: at(10, 8))   // 8:00-8:30, now 9:00
        let tick = try #require(ticks(made.item.id).first)
        #expect(ticks(made.item.id).count == 1 && tick.source == .timeline && tick.localDay == tuesday)
        #expect(block(made.block.id).tickId == tick.id && made.block.tickId == tick.id)
        #expect(try row(made.item.id)?.isDone == true)
        try clew.blockNotFinished(id: made.block.id)
        let undone = try row(made.item.id)
        #expect(ticks(made.item.id).isEmpty && undone?.isDone == false)
        // A block that has not ended yet leaves the task to do.
        let open = try clew.addOnTimeline(title: "now", start: at(10, 8, 45))   // until 9:15
        #expect(ticks(open.item.id).isEmpty && open.block.decidedAt == nil)
    }

    // MARK: Deciding

    @Test func aBlocksEndTicksTheTaskOnce() throws {
        let id = try task()
        let b = try clew.placeOnTimeline(itemId: id, start: at(10, 10))
        try settle(at: at(10, 10, 29))
        #expect(ticks(id).isEmpty && block(b.id).decidedAt == nil)
        try settle(at: at(10, 10, 31))
        let tick = try #require(ticks(id).first)
        #expect(tick.source == .timeline && tick.localDay == tuesday && tick.at == at(10, 10, 31))
        #expect(block(b.id).tickId == tick.id && block(b.id).decidedAt == at(10, 10, 31))
        #expect(try row(id)?.isDone == true)
        #expect(try clew.settleBlocks() == false)          // nothing left to do: writes nothing
        #expect(ticks(id).count == 1)
    }

    @Test func aGoalGetsPlusOneUntilItsTotalIsReached() throws {
        let id = try goal(2)
        clock.set(at(10, 8)); try clew.checkIn(itemId: id)   // 1/2, before the block was placed
        clock.set(at(10, 9))
        let a = try clew.placeOnTimeline(itemId: id, start: at(10, 10))
        try clew.addBlock(after: a.id)
        try settle(at: at(10, 10, 30))
        #expect(ticks(id).count == 2)                      // the 8:00 tick did not cover it
        #expect(block(a.id).tickId != nil)
        let second = try #require(store.state.timeBlocks.values.first { $0.id != a.id })
        try settle(at: at(10, 11))
        #expect(ticks(id).count == 2 && block(second.id).decidedAt != nil && block(second.id).tickId == nil)
    }

    @Test func twoBlocksInARowArePlusOneEach() throws {
        // A block's own tick is not a hand tick: it never covers the next block.
        let id = try goal()
        let a = try clew.placeOnTimeline(itemId: id, start: at(10, 10))
        try clew.addBlock(after: a.id)
        try settle(at: at(10, 10, 30))
        try settle(at: at(10, 11))
        #expect(ticks(id, source: .timeline).count == 2)
    }

    @Test func aTickByHandBeforeTheEndCountsForTheBlock() throws {
        let id = try goal()
        let b = try clew.placeOnTimeline(itemId: id, start: at(10, 10))
        clock.set(at(10, 10, 10))
        let hand = try clew.checkIn(itemId: id)
        try settle(at: at(10, 10, 30))
        #expect(ticks(id).map(\.id) == [hand.id] && block(b.id).coverId == hand.id)
        #expect(try clew.timeline().blocks.first?.state == .covered)
        // One hand tick covers one block: a second block needs its own.
        let c = try clew.addBlock(after: b.id)
        try settle(at: at(10, 11))
        #expect(ticks(id).count == 2 && block(c.id).tickId != nil)
    }

    @Test func aDoneTaskOrHabitIsNotTickedAgain() throws {
        let id = try task()
        let b = try clew.placeOnTimeline(itemId: id, start: at(10, 10))
        clock.set(at(10, 9, 50)); try clew.checkIn(itemId: id)
        try settle(at: at(10, 10, 30))
        #expect(ticks(id).count == 1 && block(b.id).tickId == nil && block(b.id).decidedAt != nil)
        let habit = try clew.addItem(NewItem(title: "stretch", shape: .habit(.daily))).id
        try clew.checkIn(itemId: habit)
        let h = try clew.placeOnTimeline(itemId: habit, start: at(10, 11))
        try settle(at: at(10, 11, 30))
        #expect(ticks(habit).count == 1 && block(h.id).tickId == nil)
        #expect(try clew.timeline().blocks.map(\.state) == [.skipped, .skipped])
    }

    @Test func aBlockDecidesOnceSoAnUntickHolds() throws {
        let id = try task()
        let b = try clew.placeOnTimeline(itemId: id, start: at(10, 10))
        clock.set(at(10, 9, 50)); try clew.checkIn(itemId: id)
        try settle(at: at(10, 10, 30))
        clock.set(at(10, 10, 35)); try clew.undoToday(itemId: id)
        try settle(at: at(10, 12))
        #expect(ticks(id).isEmpty && block(b.id).tickId == nil)
        // Its own tick undone with the row's undo stays undone too.
        let other = try task("other")
        let o = try clew.placeOnTimeline(itemId: other, start: at(10, 12))
        try settle(at: at(10, 12, 30))
        try clew.undoToday(itemId: other)
        try settle(at: at(10, 13))
        #expect(ticks(other).isEmpty)
        #expect(try clew.timeline().blocks.first { $0.id == o.id }?.state == .undone)
    }

    @Test func notFinishedUndoesTheBlocksTickForGood() throws {
        let id = try task()
        let b = try clew.placeOnTimeline(itemId: id, start: at(10, 10))
        try settle(at: at(10, 10, 30))
        try clew.blockNotFinished(id: b.id)
        try settle(at: at(10, 11))
        #expect(ticks(id).isEmpty && block(b.id).removedAt == nil)
        #expect(throws: ClewError.notAllowed) { try clew.blockNotFinished(id: b.id) }
    }

    @Test func changingTheEndUndoesTheTickAndDecidesAgain() throws {
        let id = try task()
        let b = try clew.placeOnTimeline(itemId: id, start: at(10, 9))
        try settle(at: at(10, 9, 30))
        let first = try #require(ticks(id).first)
        // To a later hour: the tick is undone; it ticks again when the new end passes.
        try clew.moveBlock(id: b.id, start: at(10, 14))
        #expect(ticks(id).isEmpty && block(b.id).decidedAt == nil)
        try settle(at: at(10, 14, 30))
        #expect(ticks(id).count == 1 && ticks(id).first?.id != first.id)
        // Resized so it has already ended: decides at once.
        clock.set(at(10, 16))
        try clew.resizeBlock(id: b.id, minutes: 15)
        #expect(ticks(id).count == 1 && block(b.id).decidedAt == at(10, 16))
        // Also after Not finished: a move lets it tick again.
        try clew.blockNotFinished(id: b.id)
        try clew.moveBlock(id: b.id, start: at(10, 15))
        #expect(ticks(id).count == 1)
    }

    @Test func aHandTickAUsedStaysWithItsBlock() throws {
        let id = try goal()
        let b = try clew.placeOnTimeline(itemId: id, start: at(10, 10))
        clock.set(at(10, 9, 45)); try clew.checkIn(itemId: id)
        try settle(at: at(10, 10, 30))
        try clew.moveBlock(id: b.id, start: at(10, 14))
        try settle(at: at(10, 14, 30))
        #expect(ticks(id).count == 1)                     // covered again, not +1
        // Removing it does not free the hand tick for another block.
        try clew.removeBlock(id: b.id)
        let c = try clew.placeOnTimeline(itemId: id, start: at(10, 15))
        try settle(at: at(10, 15, 30))
        #expect(ticks(id).count == 2 && block(c.id).tickId != nil)
    }

    @Test func oneHandTickCoversOnlyOneOfTwoBlocks() throws {
        let id = try goal()
        let a = try clew.placeOnTimeline(itemId: id, start: at(10, 10))
        let b = try clew.addBlock(after: a.id)              // both placed at 9:00
        clock.set(at(10, 10, 10)); try clew.checkIn(itemId: id)
        try settle(at: at(10, 10, 30))
        try settle(at: at(10, 11))
        #expect(block(a.id).coverId != nil && block(b.id).tickId != nil && ticks(id).count == 2)
    }

    @Test func anUndoneHandTickCoversNothing() throws {
        let id = try goal()
        let b = try clew.placeOnTimeline(itemId: id, start: at(10, 10))
        clock.set(at(10, 9, 45)); try clew.checkIn(itemId: id)
        clock.set(at(10, 9, 50)); try clew.undoToday(itemId: id)
        try settle(at: at(10, 10, 30))
        #expect(ticks(id).count == 1 && block(b.id).tickId != nil)
    }

    @Test func removingABlockTakesItsTickButNeverAHandTick() throws {
        let id = try goal()
        let b = try clew.placeOnTimeline(itemId: id, start: at(10, 9))
        try settle(at: at(10, 9, 30))
        clock.set(at(10, 9, 40)); try clew.checkIn(itemId: id)
        try clew.removeBlock(id: b.id)
        #expect(ticks(id).map(\.source) == [.user] && block(b.id).removedAt == at(10, 9, 40))
        #expect(try clew.timeline().blocks.isEmpty)
        #expect(throws: ClewError.notAllowed) { try clew.moveBlock(id: b.id, start: at(10, 12)) }
    }

    @Test func aClosedRoundKeepsTheBlocksTick() throws {
        let id = try goal(2)
        clock.set(at(10, 8)); try clew.checkIn(itemId: id)
        clock.set(at(10, 9))
        let b = try clew.placeOnTimeline(itemId: id, start: at(10, 9))
        try settle(at: at(10, 9, 30))                      // 2/2 reached by the block
        clock.set(at(10, 9, 31)); try clew.startNextRound(itemId: id)
        #expect(try clew.timeline().blocks.first?.canChange == false)
        #expect(throws: ClewError.notAllowed) { try clew.moveBlock(id: b.id, start: at(10, 12)) }
        #expect(throws: ClewError.notAllowed) { try clew.resizeBlock(id: b.id, minutes: 45) }
        #expect(throws: ClewError.notAllowed) { try clew.blockNotFinished(id: b.id) }
        try clew.removeBlock(id: b.id)
        #expect(ticks(id).count == 2)
    }

    @Test func aRaisedTargetIsNotARound() throws {
        let id = try goal(2)
        clock.set(at(10, 8)); try clew.checkIn(itemId: id)
        clock.set(at(10, 9))
        let b = try clew.placeOnTimeline(itemId: id, start: at(10, 9))
        try settle(at: at(10, 9, 30))
        try clew.editItem(id: id, ItemEdit(title: "read", url: nil, schedule: .daily, target: 4))
        try clew.blockNotFinished(id: b.id)
        #expect(ticks(id).count == 1)
    }

    // MARK: Sleep, rollover, leaving Today

    @Test func aBlockMissedInSleepTicksForItsOwnDayAndCanBeUndone() throws {
        let id = try task()
        let b = try clew.placeOnTimeline(itemId: id, start: at(10, 22, 30))
        try settle(at: at(11, 9))                          // Wednesday morning
        let tick = try #require(ticks(id).first)
        #expect(tick.localDay == tuesday && tick.at == at(11, 9) && block(b.id).tickId == tick.id)
        let late = try clew.lateTicks()
        #expect(late.map(\.itemId) == [id] && late.first?.day == tuesday && late.first?.canUndo == true)
        try clew.undoLateTicks(itemId: id)
        #expect(try ticks(id).isEmpty && clew.lateTicks().isEmpty)
        #expect(try row(id) != nil)                        // not done: back on Today
    }

    @Test func theEarlierDaysLineCanBeClosed() throws {
        let id = try task()
        try clew.placeOnTimeline(itemId: id, start: at(10, 22, 30))
        try settle(at: at(11, 9))
        try clew.dismissLateTicks(itemId: id)
        #expect(try clew.lateTicks().isEmpty && ticks(id).count == 1)
        // The next day it is gone by itself.
        clock.set(at(12, 9))
        #expect(throws: ClewError.notAllowed) { try clew.undoLateTicks(itemId: id) }
    }

    @Test func aGoalReachedInSleepStaysOnTodayToCongratulate() throws {
        let id = try goal(1)
        try clew.placeOnTimeline(itemId: id, start: at(10, 22, 30))
        try settle(at: at(11, 9))
        let r = try #require(try row(id))
        #expect(r.isGoalReached && r.isDone)
        clock.set(at(12, 9))
        #expect(try row(id) == nil)                        // gone after the next rollover
    }

    @Test func aBlockEndingAtFourBelongsToTheDayThatEnds() throws {
        let id = try task()
        try clew.placeOnTimeline(itemId: id, start: at(11, 3, 30))
        try settle(at: at(11, 4))
        #expect(ticks(id).first?.localDay == tuesday)
    }

    @Test func theRolloverIsNotLeavingToday() throws {
        // A Tuesday-only habit, block at 23:00, the Mac asleep until Wednesday.
        let id = try clew.addItem(NewItem(title: "bins", shape: .habit(.weekdays([.tuesday])))).id
        try clew.placeOnTimeline(itemId: id, start: at(10, 23))
        // A task moved to Later before Clew settled never ticks, even a day later.
        let gone = try task("gone")
        try clew.placeOnTimeline(itemId: gone, start: at(10, 23))
        try clew.moveToLater(itemId: gone)
        try settle(at: at(11, 8))
        #expect(ticks(id).first?.localDay == tuesday)
        #expect(ticks(gone).isEmpty)
    }

    @Test func aTaskDoneSinceIsNotTickedLate() throws {
        let id = try task()
        try clew.placeOnTimeline(itemId: id, start: at(10, 22, 30))
        clock.set(at(11, 8, 59)); try clew.checkIn(itemId: id)   // done Wednesday before Clew settled
        try settle(at: at(11, 9))
        #expect(ticks(id).count == 1 && ticks(id).first?.source == .user)
    }

    @Test func aTaskThatLeavesTodayLosesItsBlocksButKeepsItsTicks() throws {
        let a = try task("a")
        let ba = try clew.placeOnTimeline(itemId: a, start: at(10, 11))
        try clew.moveToLater(itemId: a)
        try settle(at: at(10, 10))                         // before its end: removed at once
        #expect(block(ba.id).removedAt == at(10, 10))
        try settle(at: at(10, 12))
        #expect(ticks(a).isEmpty)
        try clew.planForToday(itemIds: [a])                // back the same day, without blocks
        #expect(try clew.timeline().blocks.isEmpty)
        // Before Clew settles, a block of a task gone from Today gets no second block.
        let c = try task("c")
        let bc = try clew.placeOnTimeline(itemId: c, start: at(10, 15))
        try clew.moveToLater(itemId: c)
        #expect(throws: ClewError.notAllowed) { try clew.addBlock(after: bc.id) }
        let b = try task("b")
        let bb = try clew.placeOnTimeline(itemId: b, start: at(10, 13))
        try settle(at: at(10, 13, 30))
        try clew.deleteItem(itemId: b)
        try settle(at: at(10, 14))
        #expect(block(bb.id).removedAt != nil && ticks(b).count == 1)
        // Undoing the delete brings the task back to the list, without its block.
        try clew.undeleteItem(itemId: b)
        try settle(at: at(10, 14, 1))
        #expect(try clew.timeline().placedItems.isEmpty && row(b) != nil)
    }

    // MARK: Focus, alerts, display

    @Test func focusDoneAddsNothingWhenABlockTickedDuringIt() throws {
        let id = try goal()
        try clew.placeOnTimeline(itemId: id, start: at(10, 10))
        clock.set(at(10, 10, 10)); try clew.startFocus(itemId: id, minutes: 25)
        try settle(at: at(10, 10, 30))                     // the block ticks while the timer runs
        clock.set(at(10, 10, 40))
        #expect(try clew.finishFocus() == nil)
        #expect(ticks(id).count == 1)
        // Undone first: Done ticks as usual.
        let t = try task()
        try clew.placeOnTimeline(itemId: t, start: at(10, 11))
        clock.set(at(10, 11)); try clew.startFocus(itemId: t, minutes: 45)
        try settle(at: at(10, 11, 30))
        try clew.undoToday(itemId: t)
        clock.set(at(10, 11, 50))
        #expect(try clew.finishFocus() != nil)
    }

    @Test func aBlockStartAlertsATaskThatStillNeedsSomething() throws {
        let id = try task()
        let g = try goal()
        try clew.checkIn(itemId: g)                        // a goal ticked once still needs more
        let b = try clew.placeOnTimeline(itemId: id, start: at(10, 10))
        try clew.placeOnTimeline(itemId: g, start: at(10, 11))
        let done = try task("done")
        try clew.checkIn(itemId: done)
        try clew.placeOnTimeline(itemId: done, start: at(10, 12))
        func alerts() throws -> [PlannedNotification] {
            try clew.plannedNotifications().filter { $0.id.hasPrefix("clew.block.") }
        }
        let planned = try alerts()
        #expect(planned.count == 2 && planned.first?.fireAt == at(10, 10))
        #expect(planned.first?.content == .blockStarts(itemId: id, title: "write", until: b.end))
        #expect(try clew.wantsNotifications())
        try clew.setBlockAlerts(false)
        #expect(try alerts().isEmpty && !clew.wantsNotifications())
        try clew.setBlockAlerts(true)
        clock.set(at(10, 10, 5))                           // started: no alert any more
        #expect(try alerts().count == 1)
    }

    @Test func theTimelineShowsTodaysBlocksSideBySideWhenTheyOverlap() throws {
        let a = try task("a"), b = try task("b"), c = try task("c"), d = try task("d")
        try clew.placeOnTimeline(itemId: a, start: at(10, 10), minutes: 120)
        clock.set(at(10, 9, 1))                            // placed later: same start, next column
        try clew.placeOnTimeline(itemId: b, start: at(10, 10))
        try clew.placeOnTimeline(itemId: c, start: at(10, 10, 30))   // takes b's column once it is free
        try clew.placeOnTimeline(itemId: d, start: at(10, 12))
        let day = try clew.timeline()
        #expect(day.start == at(10, 4) && day.end == at(11, 4))
        #expect(day.blocks.map(\.title) == ["a", "b", "c", "d"])
        #expect(day.blocks.map(\.lane) == [0, 1, 1, 0] && day.blocks.map(\.lanes) == [2, 2, 2, 1])
        #expect(day.blocks.allSatisfy { $0.state == .pending && $0.canChange })
        #expect(day.placedItems == [a, b, c, d])
        try clew.removeBlock(id: try #require(day.blocks.first { $0.block.itemId == d }).id)
        #expect(try clew.timeline().placedItems == [a, b, c])               // d is back in the list
        #expect(try clew.today().rows.count == 4)                           // all still count
        #expect(day.nextStart(of: c, now: at(10, 9)) == at(10, 10, 30))
        #expect(day.nextStart(of: c, now: at(10, 11)) == nil)
    }

    @Test func aDragLandsOnTheQuarterHourUnderThePointer() throws {
        let day = try clew.timeline()
        #expect(Clew.quarterStart(minutesIn: 6 * 60 + 14, day: day) == at(10, 10))      // 10:14 → 10:00
        #expect(Clew.quarterStart(minutesIn: 6 * 60 + 15, day: day) == at(10, 10, 15))
        #expect(Clew.quarterStart(minutesIn: -40, day: day) == at(10, 4))                 // above the day
        #expect(Clew.quarterStart(minutesIn: 30 * 60, day: day) == at(11, 3, 45))        // below it
        #expect(Clew.snapMinutes(7) == 0 && Clew.snapMinutes(8) == 15 && Clew.snapMinutes(-23) == -30)
    }

    @Test func aDraggedBlockStartsWhereThePointerIsOnTheHours() throws {
        let day = try clew.timeline()
        // Its top 6 h 8 min after 4 a.m. → 10:15 (nearest quarter).
        #expect(Clew.blockStart(minutesIn: 6 * 60 + 8, minutes: 30, day: day) == at(10, 10, 15))
        #expect(Clew.blockStart(minutesIn: 6 * 60 + 7, minutes: 30, day: day) == at(10, 10))
        #expect(Clew.blockStart(minutesIn: -50, minutes: 30, day: day) == at(10, 4))           // above the day
        #expect(Clew.blockStart(minutesIn: 24 * 60, minutes: 60, day: day) == at(11, 3))       // still fits
    }

    @Test func theTimelineCanBeHidden() throws {
        #expect(try clew.timelineShown())
        try clew.setTimelineShown(false)
        #expect(try !clew.timelineShown())
    }

    @Test func blocksAreExported() throws {
        let id = try task()
        try clew.placeOnTimeline(itemId: id, start: at(10, 10))
        #expect(try store.read { try $0.allRecords() }.timeBlocks.map(\.itemId) == [id])
    }
}
