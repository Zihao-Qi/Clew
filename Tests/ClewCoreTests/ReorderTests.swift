import ClewCore
import ClewDomain
import Foundation
import Testing

@Suite struct ReorderTests {
    let store = FakeStore()
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("UTC")) }

    private func three() throws -> (Item, Item, Item) {
        let a = try clew.addItem(NewItem(title: "a", shape: .habit(.daily)))
        let b = try clew.addItem(NewItem(title: "b", shape: .habit(.daily)))
        let c = try clew.addItem(NewItem(title: "c", shape: .habit(.daily)))
        return (a, b, c)
    }

    @Test func movesBetweenNeighboursAndToEitherEnd() throws {
        let (a, b, c) = try three()
        try clew.moveItem(id: c.id, after: a.id, before: b.id)
        #expect(try clew.today().rows.map(\.item.title) == ["a", "c", "b"])
        try clew.moveItem(id: a.id, after: b.id, before: nil)
        #expect(try clew.today().rows.map(\.item.title) == ["c", "b", "a"])
        try clew.moveItem(id: a.id, after: nil, before: c.id)
        #expect(try clew.today().rows.map(\.item.title) == ["a", "c", "b"])
    }

    @Test func onlyTheMovedItemChanges() throws {
        let (a, b, c) = try three()
        clock.set(Date(timeIntervalSince1970: 1_800_000_060))
        try clew.moveItem(id: c.id, after: a.id, before: b.id) // both neighbours exist
        #expect(store.state.items[a.id] == a && store.state.items[b.id] == b)
        #expect(store.state.items[c.id]?.updatedAt == Date(timeIntervalSince1970: 1_800_000_060))
    }

    @Test func manyMovesIntoTheSameGapKeepOrder() throws {
        let (a, b, _) = try three()
        var above = a.id
        for i in 0..<40 {
            let x = try clew.addItem(NewItem(title: "x\(i)", shape: .habit(.daily)))
            try clew.moveItem(id: x.id, after: above, before: b.id)
            above = x.id
        }
        let titles = try clew.today().rows.map(\.item.title)
        #expect(Array(titles.prefix(42)) == ["a"] + (0..<40).map { "x\($0)" } + ["b"])
    }

    @Test func aDroppedRowTakesTheTargetsPlace() throws {
        let ids = (0..<4).map { _ in UUID() }
        let (a, b, c, d) = (ids[0], ids[1], ids[2], ids[3])
        // Down: a onto c → after c, before d.
        #expect(Clew.dropNeighbours(dragged: a, onto: c, in: ids)! == (c, d))
        // Down to the end: a onto d → after d.
        #expect(Clew.dropNeighbours(dragged: a, onto: d, in: ids)! == (d, nil))
        // Up: d onto b → after a, before b.
        #expect(Clew.dropNeighbours(dragged: d, onto: b, in: ids)! == (a, b))
        // Up to the top: c onto a → before a.
        #expect(Clew.dropNeighbours(dragged: c, onto: a, in: ids)! == (nil, a))
        #expect(Clew.dropNeighbours(dragged: b, onto: b, in: ids) == nil)
        #expect(Clew.dropNeighbours(dragged: UUID(), onto: b, in: ids) == nil)
    }

    @Test func dropThenMoveGivesTheExpectedOrder() throws {
        let (a, b, c) = try three()
        let order = try clew.today().rows.map(\.id)
        let (above, below) = try #require(Clew.dropNeighbours(dragged: a.id, onto: c.id, in: order))
        try clew.moveItem(id: a.id, after: above, before: below)
        #expect(try clew.today().rows.map(\.id) == [b.id, c.id, a.id])
    }

    @Test func nonsenseMovesAreRejected() throws {
        let (a, b, _) = try three()
        #expect(throws: ClewError.notAllowed) { try clew.moveItem(id: a.id, after: b.id, before: a.id) }
        #expect(throws: ClewError.notAllowed) { try clew.moveItem(id: a.id, after: b.id, before: b.id) }
        #expect(throws: ClewError.itemNotFound) { try clew.moveItem(id: UUID(), after: a.id, before: nil) }
        let gone = try clew.addItem(NewItem(title: "gone", shape: .today))
        try clew.deleteItem(itemId: gone.id)
        #expect(throws: ClewError.notAllowed) { try clew.moveItem(id: a.id, after: gone.id, before: nil) }
    }
}
