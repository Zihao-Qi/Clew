import ClewCore
import ClewDomain
import Foundation
import Testing

/// 2026-11-`d` at `h:m` in New York (Clew's day rolls over at 4 a.m.).
private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
}

/// SPEC 2026-11-21, "Steps in a task", on the timeline: a step's block reads
/// "Task - Step", leaves the task in the list, ticks the step at its end, and follows a
/// task block's rules for the step.
@Suite struct StepBlockTests {
    let store = FakeStore()
    let clock = TestClock(at(10, 9))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }

    func talk(_ shape: NewItemShape = .today) throws -> (task: UUID, steps: [UUID]) {
        let id = try clew.addItem(NewItem(title: "Prepare the talk", shape: shape)).id
        let steps = try ["slides", "notes", "practice"].map { try clew.addStep(taskId: id, title: $0).id }
        return (id, steps)
    }
    func shown(_ id: UUID) throws -> [String] {
        try clew.steps(taskId: id).entries.map { ($0.isDone ? "✓" : "") + $0.step.title }
    }
    func settle(at time: Date) throws { clock.set(time); try clew.settleBlocks() }
    func taskDone(_ id: UUID) throws -> Bool { try clew.today().rows.first { $0.id == id }?.isDone == true }
    func shownBlock(_ id: UUID) throws -> TimelineBlock? { try clew.timeline().blocks.first { $0.id == id } }

    @Test func aStepsBlockReadsTaskAndStepAndLeavesTheTaskInTheList() throws {
        let (id, steps) = try talk()
        let b = try clew.placeStepOnTimeline(stepId: steps[1], start: at(10, 10))
        #expect(b.minutes == 30 && b.stepId == steps[1] && b.itemId == id)
        let day = try clew.timeline()
        #expect(day.blocks.first?.title == "Prepare the talk - notes")
        #expect(!day.placedItems.contains(id) && day.placedSteps == [steps[1]])
        #expect(day.nextStart(of: id, now: at(10, 9)) == nil)
        // Dropped again elsewhere, the same block moves.
        let moved = try clew.placeStepOnTimeline(stepId: steps[1], start: at(10, 11))
        #expect(moved.id == b.id && store.state.timeBlocks.count == 1)
        // The task's own drop is its own block; Edit's open block is the task's, never a step's.
        #expect(try clew.openBlock(itemId: id) == nil)
        let own = try clew.placeOnTimeline(itemId: id, start: at(10, 12))
        #expect(try own.id != b.id && own.stepId == nil && clew.openBlock(itemId: id)?.id == own.id)
    }

    @Test func itsEndTicksTheStepAndTheLastOneFinishesTheTask() throws {
        let (id, steps) = try talk()
        try clew.tickStep(id: steps[0])
        try clew.tickStep(id: steps[1])
        let b = try clew.placeStepOnTimeline(stepId: steps[2], start: at(10, 10))
        try settle(at: at(10, 10, 20))
        #expect(try !taskDone(id) && shownBlock(b.id)?.state == .pending)
        try settle(at: at(10, 10, 30))
        #expect(try shown(id) == ["✓slides", "✓notes", "✓practice"] && taskDone(id))
        #expect(try shownBlock(b.id)?.state == .ticked)
        let tick = try #require(store.state.stepTicks.values.first { $0.stepId == steps[2] })
        #expect(tick.source == .timeline && tick.localDay == LocalDay(string: "2026-11-10")!)
    }

    @Test func itSkipsWhenTheStepOrItsTaskIsAlreadyDone() throws {
        let (id, steps) = try talk()
        let first = try clew.placeStepOnTimeline(stepId: steps[0], start: at(10, 10))
        try clew.tickStep(id: steps[0])                      // by hand, before its end
        try settle(at: at(10, 10, 30))
        #expect(try shownBlock(first.id)?.state == .skipped)
        let second = try clew.placeStepOnTimeline(stepId: steps[1], start: at(10, 11))
        try clew.checkIn(itemId: id)                         // the task finished at once
        try settle(at: at(10, 11, 30))
        #expect(try shownBlock(second.id)?.state == .skipped)
        #expect(store.state.stepTicks.values.filter { $0.source == .timeline }.isEmpty)
    }

    @Test func notFinishedMovingAndRemovingUntickTheStepAndItsTask() throws {
        let (id, steps) = try talk()
        try clew.tickStep(id: steps[0])
        try clew.tickStep(id: steps[1])
        let b = try clew.placeStepOnTimeline(stepId: steps[2], start: at(10, 9))   // started already
        try settle(at: at(10, 9, 30))
        #expect(try taskDone(id))
        try clew.blockNotFinished(id: b.id)
        #expect(try shown(id) == ["✓slides", "✓notes", "practice"] && !taskDone(id))
        #expect(try shownBlock(b.id)?.state == .undone)
        #expect(throws: ClewError.notAllowed) { try clew.blockNotFinished(id: b.id) }
        // Moved to an end that has passed: it decides again and ticks; then removed: unticked.
        clock.set(at(10, 11))
        try clew.moveBlock(id: b.id, start: at(10, 10))
        #expect(try taskDone(id) && shownBlock(b.id)?.state == .ticked)
        try clew.moveBlock(id: b.id, start: at(10, 12))        // its end has not passed now
        #expect(try !taskDone(id) && shown(id) == ["✓slides", "✓notes", "practice"])
        try clew.moveBlock(id: b.id, start: at(10, 9))
        #expect(try taskDone(id))
        try clew.removeBlock(id: b.id)
        #expect(try !taskDone(id) && shown(id) == ["✓slides", "✓notes", "practice"])
        #expect(try clew.timeline().blocks.isEmpty)
    }

    @Test func removingOrMovingABlockThatTickedAStepOpensThatStep() throws {
        let (id, steps) = try talk()
        let b = try clew.placeStepOnTimeline(stepId: steps[0], start: at(10, 9))
        try settle(at: at(10, 9, 30))
        #expect(try shown(id).first == "✓slides" && !taskDone(id))
        try clew.moveBlock(id: b.id, start: at(10, 11))       // its end has not passed now
        #expect(try shown(id) == ["slides", "notes", "practice"])
        try clew.moveBlock(id: b.id, start: at(10, 9))        // ended: it ticks again
        #expect(try shown(id).first == "✓slides")
        try clew.removeBlock(id: b.id)
        #expect(try shown(id) == ["slides", "notes", "practice"])
    }

    @Test func aStepTickedByHandIsNotUndoneByItsBlock() throws {
        let (id, steps) = try talk()
        let b = try clew.placeStepOnTimeline(stepId: steps[0], start: at(10, 10))
        try clew.tickStep(id: steps[0])
        try clew.removeBlock(id: b.id)                       // the block made no tick
        #expect(try shown(id).first == "✓slides")
    }

    @Test func aDeletedStepTakesItsBlockAndAnotherBlockKeepsItsStep() throws {
        let (_, steps) = try talk()
        let b = try clew.placeStepOnTimeline(stepId: steps[0], start: at(10, 10))
        let next = try clew.addBlock(after: b.id)
        #expect(next.stepId == steps[0] && next.start == at(10, 10, 30))
        try clew.deleteStep(id: steps[0])
        #expect(try clew.timeline().blocks.isEmpty)
        try clew.settleBlocks()
        #expect(store.state.timeBlocks.values.allSatisfy { $0.removedAt != nil })
    }

    @Test func deletingAStepTakesItsBlocksAtOnceAndUndoLeavesThemOff() throws {
        let (_, steps) = try talk()
        let b = try clew.placeStepOnTimeline(stepId: steps[0], start: at(10, 10))
        try clew.deleteStep(id: steps[0])                     // no settle in between
        #expect(store.state.timeBlocks[b.id]?.removedAt != nil)
        try clew.undeleteStep(id: steps[0])
        #expect(try clew.timeline().blocks.isEmpty)
    }

    @Test func anExportKeepsAStepsBlockAsTheStepsAndItsTick() throws {
        let (_, steps) = try talk()
        try clew.placeStepOnTimeline(stepId: steps[0], start: at(10, 9))
        try settle(at: at(10, 9, 30))
        let data = try clew.exportDocument().encoded()
        let back = try ExportDocument.decode(data).records.timeBlocks
        #expect(back.first?.stepId == steps[0] && back.first?.stepTickId != nil)
    }

    @Test func aLastStepFinishedOvernightShowsInTickedForYesterday() throws {
        let (id, steps) = try talk()
        try clew.tickStep(id: steps[0])
        try clew.tickStep(id: steps[1])
        try clew.placeStepOnTimeline(stepId: steps[2], start: at(11, 3))   // 3:00 a.m., still the 10th's day
        try settle(at: at(11, 9))                            // asleep past 4 a.m.
        let late = try clew.lateTicks()
        #expect(late.map(\.itemId) == [id] && late.first?.canUndo == true)
        try clew.undoLateTicks(itemId: id)
        #expect(try shown(id) == ["✓slides", "✓notes", "practice"])
    }

    @Test func aStepOfAGoalsAndLaterTaskBringsItsTaskToToday() throws {
        let (id, steps) = try talk(.later)
        try clew.placeStepOnTimeline(stepId: steps[0], start: at(10, 10))
        #expect(try clew.today().moved.contains(id))
        #expect(try clew.today().rows.contains { $0.id == id })
    }

    @Test func itsStartAlertNamesTheStepWhileItIsOpen() throws {
        let (_, steps) = try talk()
        try clew.placeStepOnTimeline(stepId: steps[1], start: at(10, 10))
        try clew.placeStepOnTimeline(stepId: steps[0], start: at(10, 11))
        try clew.tickStep(id: steps[0])                      // done: no alert for its block
        let titles = try clew.plannedNotifications().compactMap { n -> String? in
            if case .blockStarts(_, let title, _) = n.content { return title }
            return nil
        }
        #expect(titles == ["Prepare the talk - notes"])
    }

    /// SPEC 2026-11-22: a task its last step's block finished, reopened by a new step: the
    /// step stays done, its block still reads ticked, and Not finished still unticks it.
    @Test func reopeningKeepsTheFinishingStepsBlockTicked() throws {
        let (id, steps) = try talk()
        try clew.tickStep(id: steps[0])
        try clew.tickStep(id: steps[1])
        let b = try clew.placeStepOnTimeline(stepId: steps[2], start: at(10, 10))
        try settle(at: at(10, 10, 30))
        let finishing = try #require(store.state.stepTicks.values.first { $0.stepId == steps[2] && $0.voidedAt == nil })
        clock.set(at(10, 11))                                     // later: the tick keeps its own time
        try clew.addStep(taskId: id, title: "rehearse")
        #expect(try !taskDone(id) && shown(id) == ["✓slides", "✓notes", "✓practice", "rehearse"])
        let live = store.state.stepTicks.values.filter { $0.stepId == steps[2] && $0.voidedAt == nil }
        #expect(live.count == 1 && live.first?.at == finishing.at && live.first?.finishedCheckInId == nil)
        #expect(store.state.stepTicks[finishing.id]?.voidedAt != nil)
        #expect(try shownBlock(b.id)?.state == .ticked)
        try clew.blockNotFinished(id: b.id)
        #expect(try shown(id) == ["✓slides", "✓notes", "practice", "rehearse"])
    }

    /// SPEC 2026-11-22: placed steps stay listed; once every open step is on the timeline
    /// the task's row leaves the list, and comes back when one returns.
    @Test func theTaskLeavesTheListOnlyWhenEveryOpenStepIsPlaced() throws {
        let (id, steps) = try talk()
        try clew.tickStep(id: steps[0])
        func hidden() throws -> Bool {
            try clew.timeline().tasksWithAllStepsPlaced(clew.steps(taskIds: [id])).contains(id)
        }
        let first = try clew.placeStepOnTimeline(stepId: steps[1], start: at(10, 10))
        #expect(try !hidden())                                     // "practice" is still open, unplaced
        #expect(try clew.timeline().nextStart(ofStep: steps[1], now: at(10, 9)) == at(10, 10))
        #expect(try clew.timeline().nextStart(ofStep: steps[1], now: at(10, 10, 30)) == nil)
        try clew.placeStepOnTimeline(stepId: steps[2], start: at(10, 11))
        #expect(try hidden())                                      // every open step is placed
        try clew.removeBlock(id: first.id)                         // back onto the list
        #expect(try !hidden())
        // Done: no open step, so it stays in the list.
        try clew.checkIn(itemId: id)
        #expect(try !hidden())
    }
}
