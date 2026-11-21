import ClewCore
import ClewDomain
import Foundation
import Testing

private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
}

/// SPEC 2026-11-21, "Steps in a task": adding, ticking one by one, the task's own tick
/// finishing it at once, unticking back to how the steps were, order and counting.
@Suite struct StepTests {
    let store = FakeStore()
    let clock = TestClock(at(11, 9))           // Wednesday 2026-11-11
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }

    func task(_ title: String = "Prepare the talk", _ shape: NewItemShape = .today) throws -> UUID {
        try clew.addItem(NewItem(title: title, shape: shape)).id
    }
    /// A task with steps "slides", "notes", "practice".
    func talk() throws -> (task: UUID, steps: [UUID]) {
        let id = try task()
        let steps = try ["slides", "notes", "practice"].map { try clew.addStep(taskId: id, title: $0).id }
        return (id, steps)
    }
    func shown(_ id: UUID) throws -> [String] {
        try clew.steps(taskId: id).entries.map { ($0.isDone ? "✓" : "") + $0.step.title }
    }
    func later(_ minutes: Int) { clock.set(clock.now().addingTimeInterval(TimeInterval(minutes * 60))) }
    func taskDone(_ id: UUID) throws -> Bool { try clew.today().rows.first { $0.id == id }?.isDone == true }

    @Test func onlyOneOffTasksHaveStepsAndADoneTaskTakesNoNewOne() throws {
        let habit = try clew.addItem(NewItem(title: "run", shape: .habit(.daily))).id
        let goal = try clew.addItem(NewItem(title: "books", shape: .goal(target: 30))).id
        let link = try clew.addItem(NewItem(title: "read", url: URL(string: "https://example.com")!, shape: .later)).id
        #expect(throws: ClewError.notAllowed) { try clew.addStep(taskId: habit, title: "a") }
        #expect(throws: ClewError.notAllowed) { try clew.addStep(taskId: goal, title: "a") }
        try clew.addStep(taskId: link, title: "skim")   // a link (Later, with a URL) can
        #expect(throws: ClewError.emptyTitle) { try clew.addStep(taskId: link, title: "   ") }
        let done = try task("done")
        try clew.checkIn(itemId: done)
        #expect(throws: ClewError.notAllowed) { try clew.addStep(taskId: done, title: "a") }
        #expect(try shown(link) == ["skim"])
    }

    @Test func stepsTickOneByOneAndTheLastFinishesTheTask() throws {
        let (id, steps) = try talk()
        #expect(try clew.tickStep(id: steps[0]) == nil)
        later(5)
        #expect(try clew.tickStep(id: steps[1]) == nil)
        #expect(try !taskDone(id))
        later(5)
        let finished = try clew.tickStep(id: steps[2])
        #expect(finished?.itemId == id)
        #expect(try taskDone(id))
        #expect(try shown(id) == ["✓slides", "✓notes", "✓practice"])
        #expect(try clew.tickStep(id: steps[0]) == nil)   // nothing more on a done task
    }

    @Test func doneStepsComeFirstInTheOrderTheyWereDone() throws {
        let (id, steps) = try talk()
        try clew.tickStep(id: steps[2])
        later(1)
        try clew.tickStep(id: steps[0])
        #expect(try shown(id) == ["✓practice", "✓slides", "notes"])
    }

    @Test func theTasksTickFinishesItAtOnceAndUntickingPutsTheStepsBack() throws {
        let (id, steps) = try talk()
        try clew.tickStep(id: steps[0])
        later(1)
        try clew.checkIn(itemId: id)                         // the task's own circle
        #expect(try shown(id) == ["✓slides", "✓notes", "✓practice"])
        try clew.undoToday(itemId: id)
        #expect(try shown(id) == ["✓slides", "notes", "practice"])
        #expect(try !taskDone(id))
    }

    @Test func untickingATaskFinishedByItsLastStepOpensThatStep() throws {
        let (id, steps) = try talk()
        try clew.tickStep(id: steps[0])
        try clew.tickStep(id: steps[1])
        try clew.tickStep(id: steps[2])
        try clew.undoToday(itemId: id)
        #expect(try shown(id) == ["✓slides", "✓notes", "practice"])
        // And ticking it again finishes the task again.
        #expect(try clew.tickStep(id: steps[2])?.itemId == id)
    }

    @Test func untickingAStepOfADoneTaskUnticksTheTaskAndOpensThatStep() throws {
        let (id, steps) = try talk()
        try clew.tickStep(id: steps[0])
        try clew.checkIn(itemId: id)                         // finished at once
        try clew.untickStep(id: steps[2])                    // shown done only through the task
        #expect(try shown(id) == ["✓slides", "notes", "practice"])
        #expect(try !taskDone(id))
        try clew.checkIn(itemId: id)
        try clew.untickStep(id: steps[0])                    // a step done on its own
        #expect(try shown(id) == ["slides", "notes", "practice"])
    }

    @Test func untickingAnOpenTasksStepOnlyOpensThatStep() throws {
        let (id, steps) = try talk()
        try clew.tickStep(id: steps[0])
        try clew.tickStep(id: steps[1])
        try clew.untickStep(id: steps[0])
        #expect(try shown(id) == ["✓notes", "slides", "practice"])
    }

    @Test func deletingAStepNeverTicksTheTaskAndUndoBringsItBack() throws {
        let (id, steps) = try talk()
        try clew.tickStep(id: steps[0])
        try clew.tickStep(id: steps[1])
        try clew.deleteStep(id: steps[2])                    // all left are done: still open
        #expect(try shown(id) == ["✓slides", "✓notes"])
        #expect(try !taskDone(id))
        try clew.undeleteStep(id: steps[2])
        #expect(try shown(id) == ["✓slides", "✓notes", "practice"])
        for s in steps { try clew.deleteStep(id: s) }
        #expect(try clew.steps(taskId: id).isEmpty)          // a plain task again
    }

    @Test func openStepsReorderAmongThemselves() throws {
        let (id, steps) = try talk()
        let extra = try clew.addStep(taskId: id, title: "rest").id
        try clew.moveStep(id: extra, toOpenIndex: 0)
        #expect(try shown(id) == ["rest", "slides", "notes", "practice"])
        try clew.moveStep(id: steps[0], toOpenIndex: 3)
        #expect(try shown(id) == ["rest", "notes", "practice", "slides"])
        try clew.tickStep(id: steps[2])
        #expect(throws: ClewError.notAllowed) { try clew.moveStep(id: steps[2], toOpenIndex: 0) }
        #expect(try shown(id) == ["✓practice", "rest", "notes", "slides"])
        try clew.moveStep(id: steps[0], toOpenIndex: 1)      // the index counts open steps only
        #expect(try shown(id) == ["✓practice", "rest", "slides", "notes"])
    }

    @Test func manyMovesBetweenTheSameNeighboursKeepTheOrder() throws {
        let id = try task()
        _ = try clew.addStep(taskId: id, title: "a").id
        let b = try clew.addStep(taskId: id, title: "b").id
        let c = try clew.addStep(taskId: id, title: "c").id
        // Each move lands midway between "a" and its new neighbour, halving the gap until
        // there is no room left and the steps are renumbered.
        for _ in 0..<40 {
            try clew.moveStep(id: c, toOpenIndex: 1)
            try clew.moveStep(id: b, toOpenIndex: 1)
        }
        #expect(try shown(id) == ["a", "b", "c"])
        let keys = try clew.steps(taskId: id).entries.map(\.step.sortKey)
        #expect(keys == keys.sorted() && Set(keys).count == 3)
    }

    @Test func stepsNeverCountAsDoneButMakeADayActive() throws {
        let (id, steps) = try talk()
        try clew.tickStep(id: steps[0])
        let today = try clew.today()
        #expect(today.rows.first { $0.id == id }?.isDone == false)
        #expect(try clew.doneSoFar().firstDay == nil)
        #expect(try clew.activeDays().last7 == 1)
    }

    @Test func aStepTickThatFinishedAnUntickedTaskNoLongerMakesTheDayActive() throws {
        let (id, steps) = try talk()
        for s in steps.prefix(2) { try clew.deleteStep(id: s) }
        try clew.tickStep(id: steps[2])                      // the only step: finishes the task
        try clew.undoToday(itemId: id)
        #expect(try clew.activeDays().last7 == 0)
    }

    @Test func theTaskCarriesItsStepsThroughLaterTheRolloverAndDelete() throws {
        let (id, steps) = try talk()
        try clew.tickStep(id: steps[0])
        try clew.moveToLater(itemId: id)                     // done steps: the task's own tick is what counts
        #expect(try shown(id) == ["✓slides", "notes", "practice"])
        try clew.moveToToday(itemId: id)
        clock.set(at(12, 9))                                 // the next day
        #expect(try shown(id) == ["✓slides", "notes", "practice"])
        try clew.deleteItem(itemId: id)
        try clew.undeleteItem(itemId: id)
        #expect(try shown(id) == ["✓slides", "notes", "practice"])
        let exported = try clew.exportDocument().records
        #expect(exported.steps.count == 3 && exported.stepTicks.count == 1)
    }
}

/// SPEC 2026-11-21: a click folds or unfolds at once; a double-click opens the details
/// and leaves the fold as it was, whether its second click reports as a click or not.
@Suite struct FoldClickTests {
    let a = UUID(), b = UUID()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let interval: TimeInterval = 0.5

    @Test func aClickTurnsItTheOtherWay() {
        var clicks = FoldClicks()
        #expect(clicks.click(a, unfolded: false, at: t0, interval: interval) == true)
        #expect(clicks.click(a, unfolded: true, at: t0 + 2, interval: interval) == false)
    }

    @Test func aDoubleClickPutsBackTheStateBeforeItsFirstClick() {
        // Both clicks reported: folded → unfolded → folded, then the double-click.
        var clicks = FoldClicks()
        _ = clicks.click(a, unfolded: false, at: t0, interval: interval)
        _ = clicks.click(a, unfolded: true, at: t0 + 0.2, interval: interval)
        #expect(clicks.doubleClick(a, at: t0 + 0.2, interval: interval) == false)
        // Only the first click reported.
        var once = FoldClicks()
        _ = once.click(a, unfolded: true, at: t0, interval: interval)
        #expect(once.doubleClick(a, at: t0 + 0.2, interval: interval) == true)
    }

    @Test func aDoubleClickLongAfterOrOnAnotherRowLeavesItAlone() {
        var clicks = FoldClicks()
        _ = clicks.click(a, unfolded: false, at: t0, interval: interval)
        #expect(clicks.doubleClick(a, at: t0 + 5, interval: interval) == nil)
        _ = clicks.click(a, unfolded: false, at: t0, interval: interval)
        #expect(clicks.doubleClick(b, at: t0 + 0.2, interval: interval) == nil)
        // A plain row: no click recorded.
        var none = FoldClicks()
        #expect(none.doubleClick(a, at: t0, interval: interval) == nil)
    }

    @Test func aClickOnAnotherTaskStartsAFreshRecord() {
        var clicks = FoldClicks()
        _ = clicks.click(a, unfolded: false, at: t0, interval: interval)
        _ = clicks.click(b, unfolded: true, at: t0 + 0.1, interval: interval)
        #expect(clicks.doubleClick(b, at: t0 + 0.2, interval: interval) == true)
    }
}
