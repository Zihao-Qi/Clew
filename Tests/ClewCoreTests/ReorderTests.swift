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
        // A second move into the new, non-integer gap still touches nothing else.
        let movedFirst = try #require(store.state.items[c.id])
        try clew.moveItem(id: b.id, after: a.id, before: c.id)
        #expect(store.state.items[c.id] == movedFirst && store.state.items[a.id] == a)
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

    /// Halving one gap runs out of Double precision after about 50 moves; the list is
    /// then renumbered and the order still holds.
    @Test func eightyMovesIntoTheSameGapStillKeepOrder() throws {
        let (a, b, c) = try three()
        var below = b.id
        for i in 0..<80 {
            let x = try clew.addItem(NewItem(title: "x\(i)", shape: .habit(.daily)))
            try clew.moveItem(id: x.id, after: a.id, before: below) // right after a, as the UI would
            below = x.id
        }
        let titles = try clew.today().rows.map(\.item.title)
        #expect(titles == ["a"] + (0..<80).reversed().map { "x\($0)" } + ["b", "c"])
        #expect(Set(store.state.items.values.map(\.sortKey)).count == store.state.items.count)
        _ = c
    }

    @Test func theRowUnderADragIsTheOneHoldingItsCentre() {
        let ids = (0..<3).map { _ in UUID() }
        // Rows 30 pt tall at 0–30, 30–60, 60–100 (the last one taller, like a celebration row).
        let spans = [(id: ids[0], minY: 0.0, maxY: 30.0), (id: ids[1], minY: 30.0, maxY: 60.0),
                     (id: ids[2], minY: 60.0, maxY: 100.0)]
        // Row 0's centre is 15; dragging 50 down puts it at 65, inside row 2.
        #expect(Clew.rowUnderDrag(dragged: ids[0], offset: 50, spans: spans) == ids[2])
        #expect(Clew.rowUnderDrag(dragged: ids[0], offset: 20, spans: spans) == ids[1])
        // Not far enough to leave its own row: no target.
        #expect(Clew.rowUnderDrag(dragged: ids[0], offset: 10, spans: spans) == nil)
        // Up from row 2 (centre 80) by 70 → 10, inside row 0; past the top → none.
        #expect(Clew.rowUnderDrag(dragged: ids[2], offset: -70, spans: spans) == ids[0])
        #expect(Clew.rowUnderDrag(dragged: ids[2], offset: -200, spans: spans) == nil)
        // Exactly on a boundary belongs to the lower row.
        #expect(Clew.rowUnderDrag(dragged: ids[0], offset: 15, spans: spans) == ids[1])
        #expect(Clew.rowUnderDrag(dragged: UUID(), offset: 0, spans: spans) == nil)
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
