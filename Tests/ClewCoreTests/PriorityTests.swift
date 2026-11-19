import ClewCore
import ClewDomain
import Foundation
import Testing

private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
}

/// SPEC 2026-11-19, "Priority tasks": marking, the limit of 3 unfinished, until done,
/// Add and Edit, and drags staying within their group.
@Suite struct PriorityCommandTests {
    let store = FakeStore()
    let clock = TestClock(at(11, 9))           // Wednesday 2026-11-11
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }

    func add(_ title: String, _ shape: NewItemShape = .today, priority: Bool = false) throws -> UUID {
        try clew.addItem(NewItem(title: title, shape: shape, priority: priority)).id
    }
    func today() throws -> [String] { try clew.today().rows.map(\.item.title) }
    func marked(_ id: UUID) -> Bool { store.state.items[id]?.priority == true }

    @Test func upToThreeUnfinishedThenOneMoreOnceOneIsDone() throws {
        let ids = try ["a", "b", "c", "d"].map { try add($0) }
        for id in ids.prefix(3) { try clew.setPriority(itemId: id, true) }
        #expect(throws: ClewError.tooManyPriorities(max: 3)) { try clew.setPriority(itemId: ids[3], true) }
        #expect(!marked(ids[3]))
        try clew.setPriority(itemId: ids[0], true)   // marking a marked one again: nothing
        try clew.checkIn(itemId: ids[0])          // finished ones don't count
        try clew.setPriority(itemId: ids[3], true)
        #expect(try today() == ["a", "b", "c", "d"] && marked(ids[3]))
        try clew.setPriority(itemId: ids[1], false)   // unmarking always works
        #expect(try today() == ["a", "c", "d", "b"])
    }

    @Test func aTaskDoneTodayCanBeMarkedAtTheLimit() throws {
        let ids = try ["a", "b", "c"].map { try add($0, priority: true) }
        let done = try add("done")
        try clew.checkIn(itemId: done)
        try clew.setPriority(itemId: done, true)
        #expect(marked(done) && ids.allSatisfy(marked))
    }

    @Test func onlyTasksOnTodayOrHabits() throws {
        let later = try add("later", .later)
        let goal = try add("goal", .goal(target: 10))
        #expect(throws: ClewError.notAllowed) { try clew.setPriority(itemId: later, true) }
        #expect(throws: ClewError.notAllowed) { try clew.setPriority(itemId: goal, true) }
        try clew.moveToToday(itemId: goal)        // moved to Today: it can be
        try clew.setPriority(itemId: goal, true)
        // A habit not due today can be: it is a priority every day it is on Today.
        let monday = try add("monday", .habit(.weekdays([.monday])))
        try clew.setPriority(itemId: monday, true)
        #expect(marked(goal) && marked(monday) && !marked(later))
    }

    @Test func untilDone() throws {
        let habit = try add("habit", .habit(.daily))
        let once = try add("once")
        let other = try add("other")
        try clew.setPriority(itemId: habit, true)
        try clew.setPriority(itemId: once, true)
        try clew.checkIn(itemId: habit)
        clock.set(at(12, 9))                       // the next day
        #expect(try today() == ["habit", "once", "other"])   // both still first
        try clew.checkIn(itemId: once)
        clock.set(at(13, 9))
        #expect(try today() == ["habit", "other"])           // done once task: gone, as before
        _ = other
    }

    @Test func addAndEdit() throws {
        let a = try add("a", priority: true)
        let h = try add("h", .habit(.daily), priority: true)
        #expect(throws: ClewError.notAllowed) { try clew.addItem(NewItem(title: "l", shape: .later, priority: true)) }
        #expect(throws: ClewError.notAllowed) {
            try clew.addItem(NewItem(title: "g", shape: .goal(target: 5), priority: true))
        }
        let c = try add("c", priority: true)
        let count = store.state.items.count
        #expect(throws: ClewError.tooManyPriorities(max: 3)) { try clew.addItem(NewItem(title: "d", shape: .today, priority: true)) }
        #expect(store.state.items.count == count)            // nothing was added
        let d = try add("d")
        #expect(throws: ClewError.tooManyPriorities(max: 3)) {
            try clew.editItem(id: d, ItemEdit(title: "d", url: nil, priority: true))
        }
        try clew.editItem(id: a, ItemEdit(title: "a2", url: nil))               // nil keeps it
        #expect(marked(a))
        try clew.editItem(id: a, ItemEdit(title: "a2", url: nil, priority: false))
        try clew.editItem(id: d, ItemEdit(title: "d", url: nil, priority: true))
        #expect(!marked(a) && marked(d) && marked(h) && marked(c))
    }

    @Test func dragsStayWithinTheirGroup() throws {
        let p1 = try add("p1", priority: true)
        let p2 = try add("p2", priority: true)
        let n1 = try add("n1")
        let n2 = try add("n2")
        // A task dropped among the priorities lands first of the others.
        try clew.place(itemId: n2, in: .today, after: p1, before: p2)
        #expect(try today() == ["p1", "p2", "n2", "n1"])
        // A priority dropped among the others lands last of the priorities.
        try clew.place(itemId: p1, in: .today, after: n2, before: n1)
        #expect(try today() == ["p2", "p1", "n2", "n1"])
        // Within a group, as before.
        try clew.place(itemId: n1, in: .today, after: nil, before: n2)
        try clew.place(itemId: p1, in: .today, after: nil, before: p2)
        #expect(try today() == ["p1", "p2", "n1", "n2"])
        // Unmarked, it goes back among the others by its own place.
        try clew.setPriority(itemId: p2, false)
        #expect(try today().prefix(1) == ["p1"] && Set(try today().dropFirst()) == ["p2", "n1", "n2"])
    }

    @Test func aPriorityDroppedAmongTheOthersStaysLastOfItsGroup() throws {
        // Marked after the others were added: their own places are past the others'.
        let n1 = try add("n1")
        let n2 = try add("n2")
        let p1 = try add("p1", priority: true)
        let p2 = try add("p2", priority: true)
        try clew.place(itemId: p2, in: .today, after: n1, before: n2)
        #expect(try today() == ["p1", "p2", "n1", "n2"])
        try clew.place(itemId: p1, in: .today, after: n1, before: n2)
        #expect(try today() == ["p2", "p1", "n1", "n2"])
        // And a task dropped among them: first of the others.
        try clew.place(itemId: n2, in: .today, after: p2, before: p1)
        #expect(try today() == ["p2", "p1", "n2", "n1"])
    }

    @Test func placingNextToATaskNotOnTodayIsRefused() throws {
        let a = try add("a")
        let b = try add("b")
        let later = try add("later", .later)
        #expect(throws: ClewError.notAllowed) { try clew.place(itemId: b, in: .today, after: later, before: a) }
        #expect(try today() == ["a", "b"])
    }

    @Test func editCannotMarkATaskBelowButCanUnmarkIt() throws {
        let goal = try add("goal", .goal(target: 10))
        #expect(throws: ClewError.notAllowed) {
            try clew.editItem(id: goal, ItemEdit(title: "goal", url: nil, target: 10, priority: true))
        }
        try clew.moveToToday(itemId: goal)
        try clew.setPriority(itemId: goal, true)
        try clew.moveBack(itemId: goal)          // back in Goals & Later, still marked
        #expect(marked(goal))
        try clew.editItem(id: goal, ItemEdit(title: "goal", url: nil, target: 10, priority: false))
        #expect(!marked(goal))
        let a = try add("a", priority: true)
        _ = try ["b", "c"].map { try add($0, priority: true) }
        try clew.editItem(id: a, ItemEdit(title: "a", url: nil, priority: true))   // already marked, at the limit
        #expect(marked(a))
    }

    @Test func groupNeighboursAtTheEdges() {
        let p = (0..<2).map { _ in UUID() }, n = (0..<2).map { _ in UUID() }
        let order = p + n, pr = Set(p)
        func g(_ a: UUID?, _ b: UUID?, _ priority: Bool) -> [UUID?] {
            let r = Clew.groupNeighbours(after: a, before: b, in: order, priorities: pr, priority: priority)
            return [r.after, r.before]
        }
        #expect(g(n[0], n[1], true) == [p[1], nil])        // into the others: the priorities' end
        #expect(g(nil, p[0], false) == [nil, n[0]])        // into the priorities: the others' start
        #expect(g(p[1], n[0], true) == [p[1], nil])        // at the boundary
        #expect(g(p[1], n[0], false) == [nil, n[0]])
        #expect(g(p[0], p[1], true) == [p[0], p[1]])       // within: unchanged
        #expect(g(nil, nil, false) == [n[1], nil])         // nothing given: the group's end
        #expect(g(nil, nil, true) == [p[1], nil])
        let stranger = UUID()
        #expect(g(stranger, nil, true) == [stranger, nil]) // not on Today: left for place to refuse
        #expect(g(stranger, n[0], false) == [stranger, n[0]])
        #expect(g(p[0], stranger, true) == [p[0], stranger])
        #expect(g(n[0], nil, false) == [n[0], n[1]])        // after one: before the next of its group
    }
}
