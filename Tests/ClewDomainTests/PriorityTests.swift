import ClewDomain
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let wed = LocalDay(string: "2026-11-11")!

private func task(_ title: String, _ key: Double, priority: Bool = false, kind: ItemKind = .once,
                  state: ItemState = .active) -> Item {
    Item(id: UUID(), kind: kind, title: title, schedule: .unscheduled,
         progress: kind == .goal ? .counter(target: 10) : .none, state: state,
         plannedDay: kind == .once && state == .active ? wed : nil, sortKey: key, source: .user,
         priority: priority, createdAt: t0, updatedAt: t0)
}

private func ticked(_ item: Item) -> ItemFacts {
    let c = CheckIn(id: UUID(), itemId: item.id, localDay: wed, at: t0, timeZoneId: "UTC", amount: 1, source: .user)
    return ItemFacts(recent: [c], progressAmount: 1)
}

/// SPEC 2026-11-19, "Priority tasks": Today's first rows, counted for the limit and the ring.
@Suite struct PriorityTests {
    @Test func prioritiesAreTodaysFirstRowsEachGroupInItsOwnOrder() {
        let a = task("a", 1), b = task("b", 2, priority: true), c = task("c", 3), d = task("d", 4, priority: true)
        let list = todayList(items: [c, a, d, b], facts: [:], on: wed)
        #expect(list.rows.map(\.item.title) == ["b", "d", "a", "c"])
    }

    @Test func goalsAndLaterKeepTheirOrder() {
        // A marked goal or Later item below shows no priority and no order.
        let x = task("x", 1, kind: .goal), y = task("y", 2, priority: true, kind: .goal)
        let z = task("z", 3, priority: true, state: .later)
        let list = todayList(items: [z, y, x], facts: [:], on: wed)
        #expect(list.goalsAndLater.map(\.item.title) == ["x", "y", "z"])
        #expect(list.prioritiesOpen == 0 && list.prioritiesDone == 0)
    }

    @Test func doneAndOpenPrioritiesAreCountedOnTodayOnly() {
        let done = task("done", 1, priority: true), open = task("open", 2, priority: true)
        let other = task("other", 3)
        let below = task("below", 4, priority: true, kind: .goal)   // ticked in Goals & Later
        let list = todayList(items: [done, open, other, below],
                             facts: [done.id: ticked(done), other.id: ticked(other), below.id: ticked(below)], on: wed)
        #expect(list.prioritiesDone == 1)
        #expect(list.prioritiesOpen == 1)
        #expect(list.done == 3)                  // the ring's count is unchanged
    }

    @Test func tickingDoesNotMoveAPriority() {
        let a = task("a", 1, priority: true), b = task("b", 2, priority: true)
        let list = todayList(items: [a, b], facts: [a.id: ticked(a)], on: wed)
        #expect(list.rows.map(\.item.title) == ["a", "b"])
    }

    @Test func exportsFromBeforePrioritiesDecode() throws {
        let item = task("a", 1, priority: true)
        let data = try JSONEncoder().encode(item)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["priority"] as? Bool == true)
        #expect(try JSONDecoder().decode(Item.self, from: data) == item)
        object.removeValue(forKey: "priority")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Item.self, from: old)
        #expect(decoded.priority == false && decoded.title == "a")
    }
}
